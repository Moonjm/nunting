import Foundation
import os
import SDWebImage
import UIKit

/// 디스크 I/O 를 libdispatch 풀 **밖의 전용 스레드**에서 처리하는 이미지 캐시.
///
/// ## 왜 필요한가
///
/// 기기 계측(2026-08-22)이 병목을 스레드 풀 고갈로 특정했다. 이미지가 몰릴 때 전역 풀이
/// **모든 QoS 대역에서** 밀린다:
///
///   메인 큐                최대 83ms      — 멀쩡하다
///   전역 풀 .userInitiated p50 973ms
///   전역 풀 .utility       p50 1,618ms / 최대 5,417ms
///   캐시 자체의 직렬 큐     최대 194ms     — 여기도 멀쩡하다
///
/// 줄이 길어서가 아니다. 캐시 큐는 안 밀리는데 풀이 밀린다 — **파일 I/O 로 묶인
/// 스레드들이 풀의 스레드 한도를 먹고 있다**. libdispatch 는 블록된 스레드를 보고 새
/// 스레드를 만들지만 한도가 있고, 그 한도에 닿으면 디코드를 포함한 모든 블록이 순서를
/// 기다린다. 그래서 다운로드 오퍼레이션이 안 끝나고 → 슬롯이 안 풀리고 → 뒤에 선
/// 이미지는 다운로드조차 시작 못 한다(대기 p90 5초).
///
/// 근거: 디스크 I/O 를 통째로 없앤 세션에서 본문 show p90 이 5,049ms → 383ms 였다.
/// 이 클래스는 캐시 기능을 유지한 채 같은 효과를 노린다 — I/O 를 없애는 게 아니라
/// **풀 밖으로 뺀다**.
///
/// 이 그림은 그동안 실패한 시도들도 설명한다: 슬롯을 늘리면 I/O 스레드가 더 늘어 악화,
/// ioQueue 를 동시 큐로 만들면 I/O 스레드가 여러 개가 돼 악화, 읽기·쓰기 중 한쪽만
/// 없애면 나머지가 여전히 스레드를 붙잡아 무효.
///
/// ## 구조
///
/// - 메모리: `SDMemoryCache` 에 그대로 위임(NSCache 기반, 압박 시 시스템이 걷어간다).
/// - 디스크: `SDDiskCache` 의 **동기** 파일 API 를 전용 워커 스레드에서 호출한다.
///   `SDImageCache` 를 쓰지 않는 이유가 이것이다 — 그쪽은 모든 접근이 내부 `ioQueue`
///   (디스패치 큐)를 거치므로 서브클래스로는 풀에서 못 뺀다.
/// - 디코드: `SDImageCacheDecodeImageData` 를 그대로 쓴다. 썸네일 크기·스케일 같은
///   디코드 옵션이 여기서 결정되므로 컨텍스트를 **손대지 않고** 넘기는 게 중요하다.
///
/// ## 가장 위험한 실패 모드
///
/// **조용한 무효화.** 키나 컨텍스트를 잘못 넘기면 저장은 되는데 조회가 전부 미스가
/// 되고, 증상은 "그냥 좀 느림" 으로만 나타나 원인 추적이 지옥이 된다. 저장→조회
/// 왕복을 실제 디스크로 테스트한다.
// Swift 에서 `SDImageCache` 는 **클래스** 이름이고, 같은 이름의 프로토콜은 충돌 때문에
// `SDImageCacheProtocol` 로 들어온다. 우리가 채택하는 건 프로토콜 쪽이다.
/// 앱 전역 캐시 접근점. `SDImageCache.shared` 와 **섞어 쓰면 안 된다** — 메모리 캐시가
/// 둘로 갈라져(디스크 디렉터리는 같다) 한쪽에 넣은 걸 다른 쪽이 못 찾는다.
nonisolated enum AppImageCaches {
    static let disk = ThreadedImageCache()
}

/// 백그라운드 정리를 감싸는 창. 테스트가 `UIApplication` 없이 규칙을 확인할 수 있게
/// 주입 seam 을 가진 타입을 그대로 쓴다.
@MainActor
enum ImageCachePurgeWindow {
    static let shared = BackgroundFlushWindow()
}

nonisolated final class ThreadedImageCache: NSObject, SDImageCacheProtocol, @unchecked Sendable {

    /// 워커 스레드 이름 — 테스트가 "정말 풀 밖에서 도는지" 를 이 이름으로 확인한다.
    static let workerThreadName = "nunting.imageCache.diskIO"

    private let memory: SDMemoryCache<NSString, UIImage>
    private let disk: SDDiskCache
    private let worker = SerialWorker(name: ThreadedImageCache.workerThreadName)
    private var lifecycleObservers: [any NSObjectProtocol] = []

    /// 캐시 **정책값**(메모리 캡·디스크 캡·만료·쓰기 옵션). 설정을 나중에 바꾸려면
    /// **이걸** 고쳐야 한다 — `SDImageCache.shared.config` 는 남남이다. 그쪽은
    /// 생성 시점에 `.default` 를 **복사**하므로(`SDImageCache.m:127`) 거기 쓴 값은
    /// 우리 캐시에 안 온다. 실제로 그렇게 새고 있었다(Codex 리뷰 2026-08-22).
    ///
    /// 참조로 들고 있어도 되는 이유: `SDMemoryCache` 는 `maxMemoryCost` 를 KVO 로
    /// 관찰하고 `SDDiskCache` 는 쓸 때마다 읽으므로, 나중 변경도 그대로 먹는다.
    let config: SDImageCacheConfig

    /// 순정이 쓰는 것과 **같은 디렉터리** — 기존에 받아둔 파일이 그대로 살아 있다.
    ///
    /// `SDImageCache.shared.diskCachePath` 를 읽지 않는 이유가 있다. **그 접근만으로
    /// 순정 싱글턴이 만들어지고**, 그러면 그쪽도 백그라운드/종료에 자기 관찰자로
    /// 같은 디렉터리를 정리한다(`SDImageCache.m:154-166`). 두 캐시가 한 디렉터리를
    /// 각자의 큐에서 훑고 지우면, 원자적 쓰기를 꺼둔 전제 — 디스크 접근이 한 줄로
    /// 선다 — 가 깨진다.
    ///
    /// 라이브러리 내부 경로를 문자열로 재현하는 셈이라, 그게 계속 맞는지는 테스트가
    /// 지킨다(`testDefaultDirectoryMatchesLibraryPath`). 어긋나면 캐시가 조용히
    /// 새 디렉터리에서 시작할 뿐 깨지지는 않는다.
    static var defaultCacheDirectory: String {
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
        let root = (caches as NSString).appendingPathComponent("com.hackemist.SDImageCache")
        return (root as NSString).appendingPathComponent("default")
    }

    /// - Parameter cacheDirectory: 디스크 캐시 디렉터리.
    init(cacheDirectory: String = ThreadedImageCache.defaultCacheDirectory,
         config: SDImageCacheConfig = .default) {
        self.config = config
        self.memory = SDMemoryCache<NSString, UIImage>(config: config)
        // 생성 실패는 경로가 만들어질 수 없을 때뿐이다(캐시 디렉터리). 그 경우
        // 이미지 캐시 없이 도는 것보다 크래시가 낫다 — 조용히 전부 미스가 되면
        // "그냥 느린 앱" 으로 위장되기 때문이다.
        guard let disk = SDDiskCache(cachePath: cacheDirectory, config: config) else {
            preconditionFailure("디스크 캐시를 못 만들었다: \(cacheDirectory)")
        }
        self.disk = disk
        super.init()
        // 만료 정리는 **시작 시점에 하지 않는다.** 순정도 안 한다 — 백그라운드
        // 전환과 종료에만 돈다(`SDImageCache.m:154-166`). 시작 시점에 돌리면 그
        // 비용이 정확히 사용자가 첫 화면을 기다리는 순간에 얹힌다.
        let center = NotificationCenter.default
        // 두 시점의 처리가 다르다 — 순정과 같은 이유다.
        //
        // 백그라운드: 정리는 디렉터리 전체 순회 + 대량 삭제라 짧지 않은데, 그동안
        // iOS 가 프로세스를 suspend 하면 **정리가 중간에 멈춘다**. 그러면 다음
        // 포그라운드에서 워커가 그 지점부터 재개하고, 첫 조회들이 그 뒤에 줄 선다 —
        // 시작 시점 정리를 없애며 고쳤던 그 정체가 복귀 시점으로 옮겨올 뿐이다.
        // 배경 작업 창으로 끝날 시간을 확보한다.
        lifecycleObservers.append(
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: nil) { [weak self] _ in
                // UIApplication 알림은 메인에서 게시된다.
                MainActor.assumeIsolated { self?.purgeInBackgroundWindow() }
            })
        // 종료: 비동기로 넣으면 프로세스가 먼저 죽어 **아예 안 돈다**. 동기로 기다린다.
        lifecycleObservers.append(
            center.addObserver(forName: UIApplication.willTerminateNotification,
                               object: nil, queue: nil) { [weak self] _ in
                self?.purgeExpiredDataSynchronously()
            })
    }

    /// 백그라운드 정리를 배경 작업 창으로 감싼다.
    ///
    /// 창은 `FootprintLogger` 의 flush 와 같은 타입을 쓴다 — 열기/닫기 규칙(만료 시
    /// 강제 종료 방지, 겹침 카운팅)을 이미 검증해 둔 곳이라 다시 만들 이유가 없다.
    @MainActor
    private func purgeInBackgroundWindow() {
        let window = ImageCachePurgeWindow.shared
        let ticket = window.enter()
        purgeExpiredData {
            // 완료는 메인 큐로 온다(`SDCallbackQueue.main`).
            MainActor.assumeIsolated { window.leave(ticket) }
        }
    }

    /// 정리가 끝날 때까지 **기다린다.** 종료 경로 전용.
    ///
    /// 타임아웃을 두는 이유: 종료 창을 넘기면 어차피 워치독이 죽인다. 정리를 못
    /// 끝내는 건 다음 실행에서 다시 하면 되는 일이라, 붙잡고 있다 죽는 것보다 낫다.
    func purgeExpiredDataSynchronously(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        worker.async { [disk] in
            disk.removeExpiredData()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    deinit {
        let center = NotificationCenter.default
        for observer in lifecycleObservers { center.removeObserver(observer) }
        // 워커 스레드는 스스로 안 끝난다 — 안 세우면 캐시를 만들 때마다 스레드가 쌓인다.
        worker.stop()
    }

    /// 만료·용량 초과 엔트리 정리. 디렉터리 전체 순회 + 대량 삭제라 **비싸다**.
    ///
    /// 그래도 **조회와 같은 워커**에서 돈다. `SDDiskCache` 는 자체 `NSFileManager`
    /// 인스턴스를 쓰는데 그건 스레드마다 하나가 원칙이라, 다른 스레드에서 돌리면
    /// 읽기·쓰기와 같은 파일을 동시에 만지게 된다. 원자적 쓰기를 꺼둔 상태
    /// (`diskCacheWritingOptions = []`)라 그 겹침이 더 나쁘다 — 그 설정이 안전한
    /// 근거가 **디스크 접근이 한 줄로 선다**는 것이기 때문이다. 순정도 정리를
    /// 조회와 같은 `ioQueue` 에서 돌린다.
    ///
    /// 비용이 문제였던 건 스레드가 아니라 **시점**이었다. 시작 시점에 돌리면 그
    /// 비용이 첫 화면을 기다리는 순간에 얹힌다(2026-08-22 실측: 본문 show p50
    /// 139ms → 6,063ms). 그래서 백그라운드 전환/종료로 옮겼다.
    func purgeExpiredData(completion: (() -> Void)?) {
        worker.async { [disk] in
            disk.removeExpiredData()
            SDCallbackQueue.main.async { completion?() }
        }
    }

    // MARK: - SDImageCache

    /// 프로토콜의 **필수** 버전(캐시 타입 없음). 전체 조회로 위임한다.
    func queryImage(forKey key: String?,
                    options: SDWebImageOptions = [],
                    context: [SDWebImageContextOption: Any]?,
                    completion completionBlock: SDImageCacheQueryCompletionBlock?) -> (any SDWebImageOperation)? {
        queryImage(forKey: key, options: options, context: context,
                   cacheType: .all, completion: completionBlock)
    }

    func queryImage(forKey key: String?,
                    options: SDWebImageOptions = [],
                    context: [SDWebImageContextOption: Any]?,
                    cacheType queryCacheType: SDImageCacheType = .all,
                    completion completionBlock: SDImageCacheQueryCompletionBlock?) -> (any SDWebImageOperation)? {
        guard let key else {
            completionBlock?(nil, nil, .none)
            return nil
        }

        // 메모리는 동기로 — 히트면 디스크를 아예 안 건드린다.
        if queryCacheType != .disk, let image = memory.object(forKey: key as NSString) as? UIImage {
            completionBlock?(image, nil, .memory)
            return nil
        }
        if queryCacheType == .memory {
            completionBlock?(nil, nil, .none)
            return nil
        }

        let operation = CacheOperation(callback: Self.callbackQueue(context),
                                       completion: completionBlock)
        worker.async { [weak self] in
            guard let self, !operation.isCancelled else {
                operation.finish(nil, nil, .none)
                return
            }
            guard let data = self.disk.data(forKey: key) else {
                operation.finish(nil, nil, .none)
                return
            }
            // 디코드 직전에 한 번 더 본다 — 여기가 비싼 구간이라, 이미 취소된 조회에
            // 고해상도 디코드를 태우는 게 취소의 가장 큰 낭비다.
            guard !operation.isCancelled else {
                operation.finish(nil, nil, .none)
                return
            }
            // **메모리도 다시 본다.** 프리페치와 표시가 같은 이미지를 겹쳐 요청하는 건
            // 이 앱의 정상 동작이고, 둘 다 메모리 미스로 큐에 들어가면 앞 작업이
            // 메모리를 채운 뒤에도 뒤 작업이 같은 데이터를 다시 디코드한다. 워커가
            // 직렬이라 그 낭비가 뒤에 선 모든 조회를 밀기까지 한다. 순정도 같은
            // 이유로 여기서 다시 본다(`SDImageCache.m` — "Special case: If user query
            // image in list for the same URL").
            if queryCacheType != .disk,
               let cached = self.memory.object(forKey: key as NSString) as? UIImage {
                operation.finish(cached, data, .disk)
                return
            }
            // 디코드 옵션(썸네일 크기·스케일 등)이 여기서 정해진다 — 컨텍스트를
            // 손대지 않고 그대로 넘겨야 표시 경로와 같은 캐시 키/결과가 나온다.
            let image = SDImageCacheDecodeImageData(data, key, options, context)
            if let image, self.shouldCacheToMemory(context: context) {
                self.memory.setObject(image, forKey: key as NSString, cost: image.sd_memoryCost)
            }
            operation.finish(image, data, .disk)
        }
        return operation
    }

    func store(_ image: UIImage?, imageData: Data?, forKey key: String?,
               cacheType: SDImageCacheType, completion completionBlock: SDWebImageNoParamsBlock?) {
        guard let key, image != nil || imageData != nil else { completionBlock?(); return }

        if cacheType == .all || cacheType == .memory, let image {
            memory.setObject(image, forKey: key as NSString, cost: image.sd_memoryCost)
        }
        guard cacheType == .all || cacheType == .disk else { completionBlock?(); return }

        if let data = Self.diskData(image: image, imageData: imageData, key: key), !data.isEmpty {
            worker.async { [disk] in
                disk.setData(data, forKey: key)
                SDCallbackQueue.main.async { completionBlock?() }
            }
            return
        }
        // 여기까지 왔으면 **쓸 바이트가 없다** — 이미지만 있다. 거의 전부 썸네일
        // 저장이다: SD 는 썸네일에 원본 데이터를 일부러 넘기지 않고
        // (`SDWebImageManager.m` — `if (isThumbnail) { cacheData = nil; }`) 캐시가
        // 인코딩해 쓰기를 기대한다(`SDImageCache.m:272-306`).
        //
        // **우리는 일부러 안 쓴다.** 순정과 다른 선택이고, 근거는 실측이다
        // (2026-08-22, 인벤 본문 이미지):
        //
        //   encodeStore  n=4  p50 8,434ms  max 9,224ms   ← 장당 인코딩 비용
        //
        // 장당 8초다(`sd_imageDataAsFormat:` 의 기본 품질이 1.0 이라 WebP 재인코딩이
        // 극단적으로 비싸다). 33장 세션에서 4장밖에 못 끝냈다 — 비용은 전부 내면서
        // 이득은 거의 못 만든다.
        //
        // 안 써도 그림은 나온다. 매니저가 원본 키로 폴백하기 때문이다
        // (`SDWebImageManager.m` `callOriginalCacheProcessForOperation`). 대가는
        // 재방문 때 조회가 두 번 돌고 원본을 다시 다운샘플하는 것인데, 같은 세션
        // 실측이 `src=disk` p50 148ms / p90 313ms 다. 8초를 써서 그 148ms 를 조금
        // 줄이는 건 교환이 아니라 손해다.
        //
        // 되돌릴 거라면 인코딩을 싸게 만드는 쪽(품질·포맷)을 먼저 재고, 이 숫자
        // 위에서 판단할 것.
        completionBlock?()
    }

    /// 그대로 디스크에 쓸 수 있는 바이트. 없으면 nil(=인코딩이 필요하다).
    private static func diskData(image: UIImage?, imageData: Data?, key: String) -> Data? {
        // 썸네일 키에 **원본 전체** 데이터를 쓰면 안 된다. 다음 조회가 그 키로 원본을
        // 읽어 다운샘플 이득이 사라진다. 순정도 같은 판정을 한다
        // (`SDImageCache.m:263-266`, 거기선 파일 내부 `SDIsThumbnailKey`).
        if let image, image.sd_isThumbnail, Self.isThumbnailKey(key) { return nil }
        if let imageData { return imageData }
        // 커스텀 애니메 이미지는 원본 애니메 데이터를 그대로 갖고 있다 — 재인코딩
        // (움짤 전 프레임!)을 피하는 유일한 길이다.
        return (image as? any SDAnimatedImageProtocol)?.animatedImageData
    }

    /// SD 가 썸네일 키에 박는 표식. 라이브러리 쪽은 파일 스코프 static 이라 못 쓴다.
    private static func isThumbnailKey(_ key: String) -> Bool {
        key.contains("-Thumbnail(")
    }

    func removeImage(forKey key: String?, cacheType: SDImageCacheType,
                     completion completionBlock: SDWebImageNoParamsBlock?) {
        guard let key else { completionBlock?(); return }
        if cacheType == .all || cacheType == .memory {
            memory.removeObject(forKey: key as NSString)
        }
        guard cacheType == .all || cacheType == .disk else { completionBlock?(); return }
        worker.async { [disk] in
            disk.removeData(forKey: key)
            SDCallbackQueue.main.async { completionBlock?() }
        }
    }

    func containsImage(forKey key: String?, cacheType: SDImageCacheType,
                       completion completionBlock: SDImageCacheContainsCompletionBlock?) {
        guard let key else { completionBlock?(.none); return }
        if cacheType != .disk, memory.object(forKey: key as NSString) != nil {
            completionBlock?(.memory)
            return
        }
        guard cacheType != .memory else { completionBlock?(.none); return }
        worker.async { [disk] in
            let found: SDImageCacheType = disk.containsData(forKey: key) ? .disk : .none
            SDCallbackQueue.main.async { completionBlock?(found) }
        }
    }

    func clear(with cacheType: SDImageCacheType, completion completionBlock: SDWebImageNoParamsBlock?) {
        if cacheType == .all || cacheType == .memory {
            memory.removeAllObjects()
        }
        guard cacheType == .all || cacheType == .disk else { completionBlock?(); return }
        worker.async { [disk] in
            disk.removeAllData()
            SDCallbackQueue.main.async { completionBlock?() }
        }
    }

    // MARK: - 앱 코드가 쓰는 편의 API

    /// 표시 경로가 디스크 히트를 메모리로 승격할 때 쓴다(`NetworkImage`).
    func storeToMemory(_ image: UIImage, forKey key: String) {
        memory.setObject(image, forKey: key as NSString, cost: image.sd_memoryCost)
    }

    func imageFromMemoryCache(forKey key: String) -> UIImage? {
        memory.object(forKey: key as NSString) as? UIImage
    }

    func clearMemory() { memory.removeAllObjects() }

    /// 디스크 사용량. 파일 순회라 워커에서 돈다.
    func calculateDiskSize(_ completion: @escaping (UInt) -> Void) {
        worker.async { [disk] in
            let size = disk.totalSize()
            SDCallbackQueue.main.async { completion(size) }
        }
    }

    // MARK: - Private

    /// 완료 블록을 보낼 큐. 컨텍스트 지정이 있으면 그걸 쓰고, 없으면 메인이다 —
    /// 순정과 같은 규약이다(`SDImageCache.m:700` — `queue ?: SDCallbackQueue.mainQueue`).
    ///
    /// 워커 스레드에서 그대로 부르면 안 된다. 소비자가 UI 나 액터에 묶여 있으면 그
    /// 자리에서 깨지고, 지정된 큐를 무시하는 것 자체가 규약 위반이다. 매니저 경로는
    /// 자기 콜백을 따로 한 번 더 디스패치해서 이 결함이 가려져 있었을 뿐이다.
    private static func callbackQueue(_ context: [SDWebImageContextOption: Any]?) -> SDCallbackQueue {
        (context?[.callbackQueue] as? SDCallbackQueue) ?? .main
    }

    /// `SDWebImageContextStoreCacheType` 이 디스크 전용이면 메모리에 되쓰지 않는다.
    private func shouldCacheToMemory(context: [SDWebImageContextOption: Any]?) -> Bool {
        guard let raw = context?[.storeCacheType] as? Int,
              let type = SDImageCacheType(rawValue: raw) else { return true }
        return type == .all || type == .memory
    }

    /// 조회 한 건의 취소 + **정확히 한 번**의 완료를 책임진다.
    ///
    /// 순정과 같은 규약이다(`SDImageCache.m` 의 `SDImageCacheToken`): 취소하면 그
    /// 자리에서 `(nil, nil, .none)` 을 콜백 큐로 보내고, 뒤늦게 끝난 작업의 콜백은
    /// 버린다. 플래그만 세우면 취소한 쪽이 **앞선 작업이 다 끝날 때까지** 기다린다 —
    /// 뷰어를 닫거나 빠르게 스크롤할 때마다 그 대기가 쌓인다.
    ///
    /// 완료를 아예 안 보내는 선택지는 없다. 매니저가 그 콜백으로 흐름을 이어가므로
    /// 빠뜨리면 로드가 미해결로 남는다(그 모양이 "다시 시도" 고착이다).
    private final class CacheOperation: NSObject, SDWebImageOperation, @unchecked Sendable {
        private struct State {
            var cancelled = false
            var finished = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let callback: SDCallbackQueue
        private let completion: SDImageCacheQueryCompletionBlock?

        init(callback: SDCallbackQueue, completion: SDImageCacheQueryCompletionBlock?) {
            self.callback = callback
            self.completion = completion
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }

        func cancel() {
            state.withLock { $0.cancelled = true }
            finish(nil, nil, .none)
        }

        /// 첫 호출만 실제로 완료를 보낸다. 취소와 워커가 겹쳐도 콜백은 한 번뿐이다.
        func finish(_ image: UIImage?, _ data: Data?, _ type: SDImageCacheType) {
            let shouldSend = state.withLock { state -> Bool in
                guard !state.finished else { return false }
                state.finished = true
                return true
            }
            guard shouldSend, let completion else { return }
            callback.async { completion(image, data, type) }
        }
    }
}

/// libdispatch 를 쓰지 않는 직렬 워커.
///
/// `DispatchQueue` 나 `OperationQueue` 를 쓰면 결국 libdispatch 풀 스레드를 쓰게 되고,
/// 그 스레드가 파일 I/O 로 묶이는 게 지금 고치려는 문제다. 그래서 스레드를 직접 하나
/// 만들어 그 위에서만 돈다 — 풀의 한도와 무관해진다.
///
/// `internal` 인 이유는 종료 동작을 직접 테스트하기 위해서다 — 스레드가 실제로
/// 빠져나오는지는 캐시 바깥에서 관찰할 방법이 없다.
nonisolated final class SerialWorker: @unchecked Sendable {
    /// 넘겨받은 클로저를 워커 스레드로 나르는 상자.
    ///
    /// `@unchecked Sendable` 인 이유: SDWebImage 의 완료 블록과 `SDDiskCache` 는
    /// Sendable 이 아니지만, 이 상자에 담긴 클로저는 **정확히 한 번, 워커 스레드에서만**
    /// 실행된다(호출부는 넘긴 뒤 건드리지 않는다). 동시 접근이 없으므로 그 약속이 유효하다.
    private struct Job: @unchecked Sendable {
        let run: () -> Void
    }

    private let condition = NSCondition()
    private var pending: [Job] = []
    private var stopping = false
    // 클로저가 `self` 를 잡으려면 저장 프로퍼티가 다 초기화된 뒤여야 해서 `!` 다.
    // init 에서 한 번 쓰고 그 뒤로는 읽기만 한다.
    private var thread: Thread!

    /// 스레드가 빠져나왔는지. 종료 경로 검증용.
    var isFinished: Bool { thread.isFinished }

    init(name: String, qos: QualityOfService = .utility) {
        // `run()` 이 도는 동안 워커를 강하게 붙잡는다. 그래서 **종료 경로가 없으면
        // 워커도 스레드도 영원히 산다** — 앱 싱글턴이야 하나뿐이라 안 보이지만,
        // 캐시를 여러 번 만드는 쪽(테스트가 그렇다)에선 스레드가 그대로 쌓인다.
        thread = Thread { [weak self] in self?.run() }
        thread.name = name
        // 파일 I/O 는 급하지 않다 — 표시 경로와 CPU 를 다투지 않게 낮춘다.
        thread.qualityOfService = qos
        thread.start()
    }

    func async(_ block: @escaping () -> Void) {
        condition.lock()
        // 종료 중이면 큐에 넣어봤자 아무도 안 꺼낸다. 완료 블록이 영영 안 불리는
        // 것보다는 그 자리에서 실행하는 편이 호출부 계약에 가깝다.
        guard !stopping else {
            condition.unlock()
            block()
            return
        }
        pending.append(Job(run: block))
        condition.signal()
        condition.unlock()
    }

    /// 큐에 남은 일을 마저 처리하고 스레드를 끝낸다.
    ///
    /// 남은 일을 버리지 않는 이유: 그 안에 완료 블록이 들어 있어서, 버리면 기다리던
    /// 쪽이 영영 안 깨어난다.
    func stop() {
        condition.lock()
        stopping = true
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while pending.isEmpty && !stopping { condition.wait() }
            if pending.isEmpty {
                condition.unlock()
                return
            }
            let job = pending.removeFirst()
            condition.unlock()
            // **풀이 없으면 오토릴리스 객체가 스레드 수명만큼 산다.** 이 스레드는
            // 앱이 죽을 때까지 사는데, 여기서 도는 게 하필 디스크 읽기와 디코드다
            // (ObjC 임시 객체 · NSData · UIImage). 그러면 NSCache 가 이미지를
            // 걷어내도 뒤 메모리가 안 풀려 캡이 무의미해진다 — 이 앱은 그 방향으로
            // 이미 한 번 OOM 을 겪었다. `Thread` 는 풀을 만들어주지 않으므로
            // (`RunLoop` 를 안 돌리니 더더욱) 잡마다 직접 감싼다.
            autoreleasepool { job.run() }
        }
    }
}
