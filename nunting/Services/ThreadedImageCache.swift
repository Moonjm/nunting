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

nonisolated final class ThreadedImageCache: NSObject, SDImageCacheProtocol, @unchecked Sendable {

    /// 워커 스레드 이름 — 테스트가 "정말 풀 밖에서 도는지" 를 이 이름으로 확인한다.
    static let workerThreadName = "nunting.imageCache.diskIO"

    private let memory: SDMemoryCache<NSString, UIImage>
    private let disk: SDDiskCache
    private let worker = SerialWorker(name: ThreadedImageCache.workerThreadName)

    /// 캐시 **정책값**(메모리 캡·디스크 캡·만료·쓰기 옵션). 설정을 나중에 바꾸려면
    /// **이걸** 고쳐야 한다 — `SDImageCache.shared.config` 는 남남이다. 그쪽은
    /// 생성 시점에 `.default` 를 **복사**하므로(`SDImageCache.m:127`) 거기 쓴 값은
    /// 우리 캐시에 안 온다. 실제로 그렇게 새고 있었다(Codex 리뷰 2026-08-22).
    ///
    /// 참조로 들고 있어도 되는 이유: `SDMemoryCache` 는 `maxMemoryCost` 를 KVO 로
    /// 관찰하고 `SDDiskCache` 는 쓸 때마다 읽으므로, 나중 변경도 그대로 먹는다.
    let config: SDImageCacheConfig

    /// - Parameter cacheDirectory: 디스크 캐시 디렉터리. 기본값은 `SDImageCache.shared`
    ///   와 **같은 경로** — 기존에 받아둔 파일이 그대로 살아 있다.
    init(cacheDirectory: String = SDImageCache.shared.diskCachePath,
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
        // 만료 정리도 워커에서 — 이것도 파일 I/O 다.
        worker.async { [disk] in disk.removeExpiredData() }
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

        let operation = CacheOperation()
        worker.async { [weak self] in
            guard let self, !operation.isCancelled else {
                completionBlock?(nil, nil, .none)
                return
            }
            guard let data = self.disk.data(forKey: key) else {
                completionBlock?(nil, nil, .none)
                return
            }
            // 디코드 옵션(썸네일 크기·스케일 등)이 여기서 정해진다 — 컨텍스트를
            // 손대지 않고 그대로 넘겨야 표시 경로와 같은 캐시 키/결과가 나온다.
            let image = SDImageCacheDecodeImageData(data, key, options, context)
            if let image, self.shouldCacheToMemory(context: context) {
                self.memory.setObject(image, forKey: key as NSString, cost: image.sd_memoryCost)
            }
            completionBlock?(image, data, .disk)
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
                completionBlock?()
            }
            return
        }
        // 여기까지 왔으면 **쓸 바이트가 없다** — 이미지만 있다. 본문 이미지의 정상
        // 경로다: 썸네일 저장에서 SD 가 원본 데이터를 일부러 버리고
        // (`SDWebImageManager.m` — `if (isThumbnail) { cacheData = nil; }`) 캐시가
        // 인코딩해 쓰기를 기대한다. 그냥 넘기면 썸네일 키 엔트리가 영영 안 생기고,
        // 재방문마다 조회가 두 번(썸네일 미스 → 원본 히트) 돌며 원본 전체를 다시
        // 다운샘플한다. 그림은 나오므로 증상은 "그냥 느림" 으로만 보인다.
        guard let image else { completionBlock?(); return }
        // 인코딩은 CPU 작업이다. 디스크 워커에서 돌리면 뒤에 선 **조회**가 인코딩을
        // 기다린다 — 이 클래스가 없애려던 바로 그 모양이다. 순정도 같은 이유로
        // 인코딩을 별도 큐에서 하고 결과 바이트만 IO 큐에 넘긴다.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, let encoded = image.sd_imageData(as: Self.encodeFormat(for: image)),
                  !encoded.isEmpty
            else { completionBlock?(); return }
            self.worker.async { [disk = self.disk] in
                disk.setData(encoded, forKey: key)
                completionBlock?()
            }
        }
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

    /// 인코딩 포맷. 원본 포맷을 유지한다 — 다시 열 때 같은 디코더를 타고, 보드
    /// 이미지에 흔한 텍스트/스크린샷이 JPEG 재압축으로 뭉개지지 않는다. 포맷을
    /// 모르면 순정과 같은 규칙으로 정한다(알파 있으면 PNG, 없으면 JPEG).
    private static func encodeFormat(for image: UIImage) -> SDImageFormat {
        let format = image.sd_imageFormat
        guard format == .undefined else { return format }
        if image.sd_imageFrameCount > 1 { return .PNG }
        guard let cgImage = image.cgImage else { return .PNG }
        return SDImageCoderHelper.cgImageContainsAlpha(cgImage) ? .PNG : .JPEG
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
            completionBlock?()
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
            completionBlock?(disk.containsData(forKey: key) ? .disk : .none)
        }
    }

    func clear(with cacheType: SDImageCacheType, completion completionBlock: SDWebImageNoParamsBlock?) {
        if cacheType == .all || cacheType == .memory {
            memory.removeAllObjects()
        }
        guard cacheType == .all || cacheType == .disk else { completionBlock?(); return }
        worker.async { [disk] in
            disk.removeAllData()
            completionBlock?()
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
        worker.async { [disk] in completion(disk.totalSize()) }
    }

    // MARK: - Private

    /// `SDWebImageContextStoreCacheType` 이 디스크 전용이면 메모리에 되쓰지 않는다.
    private func shouldCacheToMemory(context: [SDWebImageContextOption: Any]?) -> Bool {
        guard let raw = context?[.storeCacheType] as? Int,
              let type = SDImageCacheType(rawValue: raw) else { return true }
        return type == .all || type == .memory
    }

    /// 취소 신호만 나르는 최소 오퍼레이션. SD 는 조회 반환값을 취소용으로만 쓴다.
    private final class CacheOperation: NSObject, SDWebImageOperation, @unchecked Sendable {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { cancelled.withLock { $0 } }
        func cancel() { cancelled.withLock { $0 = true } }
    }
}

/// libdispatch 를 쓰지 않는 직렬 워커.
///
/// `DispatchQueue` 나 `OperationQueue` 를 쓰면 결국 libdispatch 풀 스레드를 쓰게 되고,
/// 그 스레드가 파일 I/O 로 묶이는 게 지금 고치려는 문제다. 그래서 스레드를 직접 하나
/// 만들어 그 위에서만 돈다 — 풀의 한도와 무관해진다.
private nonisolated final class SerialWorker: @unchecked Sendable {
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

    init(name: String) {
        let thread = Thread { [weak self] in self?.run() }
        thread.name = name
        // 파일 I/O 는 급하지 않다 — 표시 경로와 CPU 를 다투지 않게 낮춘다.
        thread.qualityOfService = .utility
        thread.start()
    }

    func async(_ block: @escaping () -> Void) {
        condition.lock()
        pending.append(Job(run: block))
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while pending.isEmpty { condition.wait() }
            let job = pending.removeFirst()
            condition.unlock()
            job.run()
        }
    }
}
