import XCTest
import os
import SDWebImage
import SDWebImageWebPCoder
@testable import nunting

/// `ThreadedImageCache` — 디스크 I/O 를 libdispatch 풀 **밖의 전용 스레드**에서 하는 캐시.
///
/// 왜: 계측이 병목을 스레드 풀 고갈로 특정했다(2026-08-22). 이미지가 몰릴 때 전역 풀이
/// **모든 QoS 대역에서** 밀린다 — utility p50 1,618ms / userInitiated p50 973ms.
/// 반면 캐시 자체의 직렬 큐는 194ms 로 멀쩡하다. 즉 줄이 길어서가 아니라 **파일 I/O 로
/// 묶인 스레드들이 풀의 한도를 먹어서**다. 디스크 I/O 를 풀 밖으로 빼면 그 압력이 사라진다.
///
/// 근거: 디스크 I/O 를 통째로 없앤 세션에서 본문 show p90 이 5,049ms → 383ms 였다.
/// 이 클래스는 캐시 기능을 유지한 채 같은 효과를 노린다.
///
/// **가장 위험한 실패 모드는 조용한 무효화다.** 캐시 키나 디코드 컨텍스트를 잘못
/// 넘기면 전부 미스가 되면서 "그냥 좀 느린 앱" 이 된다. 그래서 저장→조회 왕복을
/// 실제 디스크로 검증한다.
final class ThreadedImageCacheTests: XCTestCase {

    private var cache: ThreadedImageCache!
    private var cacheDirectory = ""

    override func setUp() {
        super.setUp()
        cacheDirectory = NSTemporaryDirectory().appending("nunting-test-\(UUID().uuidString)")
        cache = ThreadedImageCache(cacheDirectory: cacheDirectory)
    }

    override func tearDown() {
        let done = expectation(description: "cleared")
        cache.clear(with: .all) { done.fulfill() }
        wait(for: [done], timeout: 5)
        cache = nil
        super.tearDown()
    }

    private func sampleImage() -> UIImage {
        UIGraphicsBeginImageContext(CGSize(width: 4, height: 4))
        defer { UIGraphicsEndImageContext() }
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }

    private func pngData() throws -> Data {
        try XCTUnwrap(sampleImage().pngData())
    }

    /// 기본 디렉터리가 **라이브러리가 쓰는 경로와 같아야** 한다.
    ///
    /// 우리는 `SDImageCache.shared.diskCachePath` 를 안 읽는다 — 그 접근만으로 순정
    /// 싱글턴이 생기고, 그러면 그쪽도 백그라운드/종료에 같은 디렉터리를 정리해서
    /// 디스크 접근 직렬성이 깨진다. 대신 경로를 직접 만드는데, 그게 계속 맞는지는
    /// 여기서 지킨다(이 테스트 안에서는 싱글턴을 만들어도 무해하다).
    func testDefaultDirectoryMatchesLibraryPath() {
        XCTAssertEqual(ThreadedImageCache.defaultCacheDirectory,
                       SDImageCache.shared.diskCachePath,
                       "라이브러리 경로 규칙이 바뀌었다 — 기존 캐시를 못 읽고 새로 시작하게 된다")
    }

    /// 저장한 걸 다시 꺼낼 수 있어야 한다. 이게 깨지면 캐시가 조용히 무효가 되고,
    /// 증상은 "느리다" 로만 나타나 원인 추적이 지옥이 된다.
    func testStoresAndQueriesBackFromDisk() throws {
        let data = try pngData()
        let stored = expectation(description: "stored")
        cache.store(sampleImage(), imageData: data, forKey: "roundtrip",
                    cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        // 메모리에는 없고 디스크에서 와야 한다.
        let queried = expectation(description: "queried")
        let result = OSAllocatedUnfairLock<(UIImage?, SDImageCacheType)>(initialState: (nil, .none))
        _ = cache.queryImage(forKey: "roundtrip", options: [], context: nil,
                             cacheType: .all) { image, _, type in
            result.withLock { $0 = (image, type) }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 5)

        let (image, type) = result.withLock { $0 }
        XCTAssertNotNil(image, "디스크에 넣은 걸 못 읽으면 캐시가 무효다")
        XCTAssertEqual(type, .disk)
    }

    /// **데이터 없이 이미지만 들어오면 디스크에 쓰지 않는다** — 의도된 선택이다.
    ///
    /// 순정은 그때 이미지를 인코딩해서 쓴다(`SDImageCache.m:272-306`). 우리는 안
    /// 쓴다. 근거는 기기 실측이다(2026-08-22): 인코딩이 장당 p50 8,434ms 였고
    /// (기본 품질 1.0 WebP 재인코딩) 33장 세션에서 4장밖에 못 끝냈다. 안 써도
    /// 매니저가 원본 키로 폴백해 그림은 나오고, 그 재방문 비용이 `src=disk`
    /// p50 148ms 다. 8초로 148ms 를 줄이는 건 교환이 아니라 손해다.
    ///
    /// 되돌릴 거라면 인코딩을 싸게 만드는 쪽을 먼저 재고 이 숫자 위에서 판단할 것.
    func testDoesNotEncodeImageWithoutDataToDisk() {
        let stored = expectation(description: "stored")
        cache.store(sampleImage(), imageData: nil, forKey: "encoded",
                    cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        XCTAssertEqual(contains("encoded", in: cache), SDImageCacheType.none,
                       "인코딩 저장이 되살아났다 — 장당 8초짜리 비용이다")
    }

    /// 반면 **애니메 이미지의 원본 데이터는 공짜로 손에 있다** — 그건 쓴다.
    /// 인코딩(움짤이면 전 프레임 재압축!)이 필요 없는 유일한 경우다.
    func testStoresAnimatedImageDataWithoutReencoding() throws {
        let frames = (0..<3).map { index in
            let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
                UIColor(white: CGFloat(index) / 3, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
            return SDImageFrame(image: image, duration: 0.05)
        }
        let animated = try XCTUnwrap(SDImageCoderHelper.animatedImage(with: frames))
        let data = try XCTUnwrap(SDImageWebPCoder.shared.encodedData(with: animated,
                                                                    format: .webP, options: nil))
        let image = try XCTUnwrap(SDAnimatedImage(data: data))

        let stored = expectation(description: "stored")
        cache.store(image, imageData: nil, forKey: "animated", cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        XCTAssertEqual(contains("animated", in: cache), .disk,
                       "손에 있는 애니메 원본 데이터까지 버리면 재방문이 전부 미스가 된다")
    }

    /// **실제 파이프라인 확인**: 썸네일 키 엔트리 없이도 재방문이 성립하는가.
    ///
    /// 본문 이미지는 거의 전부 `imageThumbnailPixelSize` 를 달고 로드되고, 우리는
    /// 그 키에 아무것도 쓰지 않는다(위 `testDoesNotEncodeImageWithoutDataToDisk`
    /// 의 근거). 그래서 이 선택이 서 있는 조건은 하나다 — **매니저가 원본 키로
    /// 폴백해 그림을 만들어 준다**(`callOriginalCacheProcessForOperation`).
    ///
    /// 그 폴백이 사라지면 재방문이 전부 네트워크가 된다. 네트워크 없이 원본만
    /// 시드해 이 경로 전체를 돌려 확인한다.
    func testThumbnailLoadFallsBackToOriginalEntry() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let data = try XCTUnwrap(SDImageWebPCoder.shared.encodedData(with: source,
                                                                    format: .webP, options: nil))
        let url = URL(string: "https://unit.test/\(UUID().uuidString)/thumb.webp")!
        let context: [SDWebImageContextOption: Any] = [
            .imageCache: cache as Any,
            .imageThumbnailPixelSize: NSValue(cgSize: CGSize(width: 16, height: 16)),
        ]
        let originalKey = try XCTUnwrap(SDWebImageManager.shared.cacheKey(for: url))
        let thumbnailKey = try XCTUnwrap(SDWebImageManager.shared.cacheKey(for: url, context: context))
        XCTAssertNotEqual(originalKey, thumbnailKey, "썸네일 키가 따로 생겨야 이 시나리오가 성립한다")

        let seeded = expectation(description: "seeded")
        cache.store(nil, imageData: data, forKey: originalKey, cacheType: .disk) { seeded.fulfill() }
        wait(for: [seeded], timeout: 5)

        let loaded = expectation(description: "loaded")
        SDWebImageManager.shared.loadImage(with: url, options: [], context: context,
                                           progress: nil) { image, _, _, _, _, _ in
            XCTAssertNotNil(image, "원본 시드가 있으니 네트워크 없이 떠야 한다")
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 10)

        XCTAssertEqual(contains(thumbnailKey, in: cache), SDImageCacheType.none,
                       "썸네일 키에 쓰기 시작했다 — 인코딩 비용이 되살아났는지 확인할 것")
    }

    /// 이미지도 데이터도 없으면 쓸 게 없다 — 완료만 알리고 끝(순정과 같은 계약).
    func testStoreWithNothingToWriteJustCompletes() {
        let done = expectation(description: "done")
        cache.store(nil, imageData: nil, forKey: "nothing", cacheType: .all) { done.fulfill() }
        wait(for: [done], timeout: 5)

        let queried = expectation(description: "queried")
        let type = OSAllocatedUnfairLock(initialState: SDImageCacheType.memory)
        _ = cache.queryImage(forKey: "nothing", options: [], context: nil, cacheType: .all) { _, _, t in
            type.withLock { $0 = t }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 5)
        XCTAssertEqual(type.withLock { $0 }, SDImageCacheType.none)
    }

    /// 메모리 히트는 디스크를 안 거치고 즉시 나와야 한다 — 그게 메모리 캐시의 전부다.
    func testMemoryHitDoesNotTouchDisk() {
        cache.store(sampleImage(), imageData: nil, forKey: "mem",
                    cacheType: .memory, completion: nil)

        let queried = expectation(description: "queried")
        let type = OSAllocatedUnfairLock(initialState: SDImageCacheType.none)
        _ = cache.queryImage(forKey: "mem", options: [], context: nil, cacheType: .all) { _, _, t in
            type.withLock { $0 = t }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 3)

        XCTAssertEqual(type.withLock { $0 }, .memory)
    }

    /// 없는 키는 `.none` 으로 답한다(콜드 캐시의 정상 경로).
    func testMissReportsNone() {
        let queried = expectation(description: "queried")
        let type = OSAllocatedUnfairLock(initialState: SDImageCacheType.memory)
        _ = cache.queryImage(forKey: "absent", options: [], context: nil, cacheType: .all) { _, _, t in
            type.withLock { $0 = t }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 3)

        XCTAssertEqual(type.withLock { $0 }, SDImageCacheType.none)
    }

    /// 삭제가 디스크까지 반영돼야 한다.
    func testRemoveClearsDisk() throws {
        let data = try pngData()
        let stored = expectation(description: "stored")
        cache.store(sampleImage(), imageData: data, forKey: "gone",
                    cacheType: .all) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        let removed = expectation(description: "removed")
        cache.removeImage(forKey: "gone", cacheType: .all) { removed.fulfill() }
        wait(for: [removed], timeout: 5)

        let queried = expectation(description: "queried")
        let type = OSAllocatedUnfairLock(initialState: SDImageCacheType.memory)
        _ = cache.queryImage(forKey: "gone", options: [], context: nil, cacheType: .all) { _, _, t in
            type.withLock { $0 = t }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 5)
        XCTAssertEqual(type.withLock { $0 }, SDImageCacheType.none)
    }

    /// **시작 시점에 만료 정리를 하지 않는다.**
    ///
    /// 한동안 init 에서 조회 워커에 태워 돌렸다. 디스크 캡이 실제로 적용되기
    /// 전까지는 싸서 안 보였는데, 캡이 걸린 첫 빌드에서 정리가 대량 삭제로 커지며
    /// **첫 조회들이 통째로 밀렸다** — 본문 show p50 139ms → 6,063ms, 그동안
    /// 다운로드 대기 p50 은 1ms 였다(병목이 다운로드 앞이라는 뜻). 순정도 시작
    /// 시점엔 안 한다(`SDImageCache.m:154-166` — 백그라운드/종료에만).
    ///
    /// 만료된 엔트리가 init 뒤에도 살아 있는 것으로 "정리를 안 했다" 를 확인한다.
    func testInitDoesNotPurgeExpiredEntries() throws {
        let directory = NSTemporaryDirectory().appending("nunting-purge-\(UUID().uuidString)")
        let config = SDImageCacheConfig()
        let seeding = ThreadedImageCache(cacheDirectory: directory, config: config)
        let stored = expectation(description: "stored")
        seeding.store(sampleImage(), imageData: try pngData(), forKey: "old",
                      cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        // 이제 "전부 만료" 로 열어도 init 이 지우면 안 된다.
        config.maxDiskAge = 0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let reopened = ThreadedImageCache(cacheDirectory: directory, config: config)
        defer {
            let cleared = expectation(description: "cleared")
            reopened.clear(with: .all) { cleared.fulfill() }
            wait(for: [cleared], timeout: 5)
        }

        XCTAssertEqual(contains("old", in: reopened), .disk,
                       "init 이 만료 정리를 돌렸다 — 그 비용이 첫 조회 앞에 얹힌다")

        // 명시적으로 부르면 그때는 지운다.
        let purged = expectation(description: "purged")
        reopened.purgeExpiredData { purged.fulfill() }
        wait(for: [purged], timeout: 5)
        XCTAssertEqual(contains("old", in: reopened), SDImageCacheType.none,
                       "명시적 정리는 만료 엔트리를 지워야 한다")
    }

    private func contains(_ key: String, in cache: ThreadedImageCache) -> SDImageCacheType {
        let probed = expectation(description: "contains")
        let found = OSAllocatedUnfairLock(initialState: SDImageCacheType.none)
        cache.containsImage(forKey: key, cacheType: .disk) { type in
            found.withLock { $0 = type }
            probed.fulfill()
        }
        wait(for: [probed], timeout: 5)
        return found.withLock { $0 }
    }

    /// **이 클래스의 존재 이유**: 디스크 읽기와 디코드가 libdispatch 풀 스레드에서
    /// 돌면 안 된다. 풀 스레드를 쓰면 지금 겪는 고갈이 그대로 재현된다.
    ///
    /// 완료 블록이 아니라 **디코드가 도는 스레드**를 본다. 완료는 콜백 큐(기본 메인)로
    /// 넘어가므로 거기서 재면 이 불변식이 아니라 콜백 규약을 재게 된다.
    func testDiskReadAndDecodeRunOffTheDispatchPool() throws {
        let manager = SDImageCodersManager.shared
        let original = manager.coders ?? []
        let probe = ThreadRecordingCoder()
        manager.addCoder(probe)
        defer { manager.coders = original }

        let stored = expectation(description: "stored")
        cache.store(nil, imageData: try pngData(), forKey: "thread",
                    cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        let queried = expectation(description: "queried")
        _ = cache.queryImage(forKey: "thread", options: [], context: nil, cacheType: .disk) { _, _, _ in
            queried.fulfill()
        }
        wait(for: [queried], timeout: 5)

        XCTAssertEqual(probe.decodeThreadName.withLock { $0 }, ThreadedImageCache.workerThreadName,
                       "디스크 디코드가 전용 스레드가 아닌 곳에서 돌았다")
    }

    /// 완료는 **콜백 큐 규약**을 따라야 한다. 순정은 `context[.callbackQueue]` 를 쓰고
    /// 없으면 메인으로 보낸다(`SDImageCache.m:700`). 우리는 워커 스레드에서 그대로
    /// 부르고 있었다 — 소비자가 UI/액터에 묶여 있으면 그 자리에서 깨진다.
    func testDiskQueryCompletionLandsOnMainByDefault() throws {
        let stored = expectation(description: "stored")
        cache.store(nil, imageData: try pngData(), forKey: "cb", cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        let queried = expectation(description: "queried")
        let onMain = OSAllocatedUnfairLock(initialState: false)
        _ = cache.queryImage(forKey: "cb", options: [], context: nil, cacheType: .disk) { _, _, _ in
            onMain.withLock { $0 = Thread.isMainThread }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 5)

        XCTAssertTrue(onMain.withLock { $0 }, "완료가 메인에서 안 왔다")
    }

    /// 컨텍스트가 큐를 지정하면 그걸 따른다 — 지정을 무시하는 건 규약 위반이다.
    func testDiskQueryCompletionHonorsContextCallbackQueue() throws {
        let stored = expectation(description: "stored")
        cache.store(nil, imageData: try pngData(), forKey: "cbq", cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        let label = "nunting.test.callbackQueue"
        let queue = DispatchQueue(label: label)
        let context: [SDWebImageContextOption: Any] = [
            .callbackQueue: SDCallbackQueue(dispatchQueue: queue)
        ]

        let queried = expectation(description: "queried")
        let seen = OSAllocatedUnfairLock(initialState: "")
        _ = cache.queryImage(forKey: "cbq", options: [], context: context, cacheType: .disk) { _, _, _ in
            seen.withLock { $0 = String(cString: __dispatch_queue_get_label(nil)) }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 5)

        XCTAssertEqual(seen.withLock { $0 }, label, "지정한 콜백 큐가 무시됐다")
    }
}

/// 디코드가 어느 스레드에서 도는지만 기록하는 코더. 디코드 자체는 하지 않고
/// (nil 반환) 다음 코더로 넘긴다 — 기록이 목적이다.
private final class ThreadRecordingCoder: NSObject, SDImageCoder, @unchecked Sendable {
    let decodeThreadName = OSAllocatedUnfairLock(initialState: "")

    func canDecode(from data: Data?) -> Bool {
        decodeThreadName.withLock { $0 = Thread.current.name ?? "" }
        return false
    }
    func decodedImage(with data: Data?, options: [SDImageCoderOption: Any]?) -> UIImage? { nil }
    func canEncode(to format: SDImageFormat) -> Bool { false }
    func encodedData(with image: UIImage?, format: SDImageFormat,
                     options: [SDImageCoderOption: Any]?) -> Data? { nil }
}

/// `SerialWorker` 의 **종료 경로**.
///
/// `run()` 은 도는 동안 워커를 강하게 붙잡는다. 종료 신호가 없으면 워커도 스레드도
/// 영원히 산다 — 앱 싱글턴은 하나뿐이라 안 보이지만, 캐시를 여러 번 만드는 쪽
/// (이 테스트 파일이 그렇다)에선 스레드가 그대로 쌓인다.
final class SerialWorkerLifecycleTests: XCTestCase {

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return condition()
    }

    func testStopEndsTheWorkerThread() {
        let worker = SerialWorker(name: "nunting.test.worker")
        let ran = expectation(description: "ran")
        worker.async { ran.fulfill() }
        wait(for: [ran], timeout: 3)
        XCTAssertFalse(worker.isFinished, "일하는 중엔 살아 있어야 한다")

        worker.stop()

        XCTAssertTrue(waitUntil { worker.isFinished }, "stop 뒤에도 스레드가 안 끝났다")
    }

    /// 큐에 남은 일은 버리지 않는다 — 그 안에 완료 블록이 있어서, 버리면 기다리던
    /// 쪽이 영영 안 깨어난다.
    func testStopDrainsPendingWork() {
        let worker = SerialWorker(name: "nunting.test.worker.drain")
        let gate = DispatchSemaphore(value: 0)
        let done = expectation(description: "queued work ran")

        worker.async { gate.wait() }   // 워커를 붙잡아 뒤 작업이 큐에 남게 한다
        worker.async { done.fulfill() }
        worker.stop()
        gate.signal()

        wait(for: [done], timeout: 3)
        XCTAssertTrue(waitUntil { worker.isFinished })
    }
}

/// 조회 **취소** 규약.
///
/// 순정 `SDImageCacheToken.cancel` 은 그 자리에서 `doneBlock(nil, nil, .none)` 을
/// 콜백 큐로 보내고, 뒤늦게 끝난 작업의 콜백은 억제한다(`SDImageCache.m` 토큰 구현).
/// 우리는 플래그만 세우고 있어서, 취소한 쪽이 **앞선 작업들이 다 끝날 때까지** 기다렸다.
/// 뷰어를 닫거나 빠르게 스크롤할 때마다 그 대기가 쌓인다.
final class ThreadedImageCacheCancellationTests: XCTestCase {

    /// 디코드를 느리게 만들어 워커를 붙잡는 코더. 디코드는 안 하고(nil) 시간만 쓴다.
    private final class SlowCoder: NSObject, SDImageCoder, @unchecked Sendable {
        let delay: TimeInterval
        init(delay: TimeInterval) { self.delay = delay }
        func canDecode(from data: Data?) -> Bool {
            Thread.sleep(forTimeInterval: delay)
            return false
        }
        func decodedImage(with data: Data?, options: [SDImageCoderOption: Any]?) -> UIImage? { nil }
        func canEncode(to format: SDImageFormat) -> Bool { false }
        func encodedData(with image: UIImage?, format: SDImageFormat,
                         options: [SDImageCoderOption: Any]?) -> Data? { nil }
    }

    private var cache: ThreadedImageCache!
    private var originalCoders: [any SDImageCoder] = []

    override func setUp() {
        super.setUp()
        cache = ThreadedImageCache(cacheDirectory: NSTemporaryDirectory()
            .appending("nunting-cancel-\(UUID().uuidString)"))
        originalCoders = SDImageCodersManager.shared.coders ?? []
    }

    override func tearDown() {
        SDImageCodersManager.shared.coders = originalCoders
        let done = expectation(description: "cleared")
        cache.clear(with: .all) { done.fulfill() }
        wait(for: [done], timeout: 5)
        cache = nil
        super.tearDown()
    }

    private func seed(_ key: String) throws {
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            .image { _ in }.pngData())
        let stored = expectation(description: "stored \(key)")
        cache.store(nil, imageData: data, forKey: key, cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)
    }

    /// 취소는 **줄을 기다리지 않는다.** 앞 작업이 워커를 0.6초 붙잡고 있어도, 취소한
    /// 조회는 그 전에 완료돼야 한다.
    func testCancelCompletesWithoutWaitingForTheQueue() throws {
        try seed("slow")
        try seed("cancelled")
        SDImageCodersManager.shared.addCoder(SlowCoder(delay: 0.6))

        // 워커를 붙잡는다.
        _ = cache.queryImage(forKey: "slow", options: [], context: nil, cacheType: .disk) { _, _, _ in }

        let cancelled = expectation(description: "cancelled completion")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let type = OSAllocatedUnfairLock(initialState: SDImageCacheType.memory)
        let op = cache.queryImage(forKey: "cancelled", options: [], context: nil,
                                  cacheType: .disk) { _, _, t in
            calls.withLock { $0 += 1 }
            type.withLock { $0 = t }
            cancelled.fulfill()
        }
        op?.cancel()

        // 앞 작업(0.6s)이 끝나기 전에 와야 한다.
        wait(for: [cancelled], timeout: 0.3)
        XCTAssertEqual(type.withLock { $0 }, SDImageCacheType.none, "취소는 .none 으로 끝나야 한다")

        // 뒤늦게 워커가 끝나도 두 번 부르면 안 된다.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))
        XCTAssertEqual(calls.withLock { $0 }, 1, "완료가 두 번 왔다 — 정확히 한 번이어야 한다")
    }

    /// 이미 완료된 조회를 취소해도 완료가 한 번 더 오면 안 된다.
    func testCancelAfterCompletionDoesNotFireAgain() throws {
        try seed("done")

        let finished = expectation(description: "finished")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let op = cache.queryImage(forKey: "done", options: [], context: nil, cacheType: .disk) { _, _, _ in
            calls.withLock { $0 += 1 }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)

        op?.cancel()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(calls.withLock { $0 }, 1)
    }
}

/// 디스크 접근의 **직렬성**과 중복 디코드.
///
/// 두 문제가 같은 뿌리다: 디스크 작업이 한 줄로 서 있는가.
final class ThreadedImageCacheSerializationTests: XCTestCase {

    /// 실제 디코드는 ImageIO 에 위임하고 **호출 횟수만** 센다.
    private final class CountingDecodeCoder: NSObject, SDImageCoder, @unchecked Sendable {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        func canDecode(from data: Data?) -> Bool { true }
        func decodedImage(with data: Data?, options: [SDImageCoderOption: Any]?) -> UIImage? {
            calls.withLock { $0 += 1 }
            return SDImageIOCoder.shared.decodedImage(with: data, options: options)
        }
        func canEncode(to format: SDImageFormat) -> Bool { false }
        func encodedData(with image: UIImage?, format: SDImageFormat,
                         options: [SDImageCoderOption: Any]?) -> Data? { nil }
    }

    private var cache: ThreadedImageCache!
    private var config: SDImageCacheConfig!
    private var originalCoders: [any SDImageCoder] = []

    override func setUp() {
        super.setUp()
        config = SDImageCacheConfig()
        cache = ThreadedImageCache(cacheDirectory: NSTemporaryDirectory()
            .appending("nunting-serial-\(UUID().uuidString)"), config: config)
        originalCoders = SDImageCodersManager.shared.coders ?? []
    }

    override func tearDown() {
        SDImageCodersManager.shared.coders = originalCoders
        let done = expectation(description: "cleared")
        cache.clear(with: .all) { done.fulfill() }
        wait(for: [done], timeout: 5)
        cache = nil
        super.tearDown()
    }

    private func seed(_ key: String) throws {
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
            .image { ctx in
                UIColor.systemPink.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }.pngData())
        let stored = expectation(description: "stored")
        cache.store(nil, imageData: data, forKey: key, cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)
    }

    /// **같은 키를 두 번 조회하면 디코드는 한 번이어야 한다.**
    ///
    /// 프리페치와 표시가 같은 이미지를 겹쳐 요청하는 게 이 앱의 정상 동작이다. 둘 다
    /// 메모리 미스로 큐에 들어가면, 앞 작업이 메모리를 채운 뒤에도 뒤 작업이 같은
    /// 데이터를 다시 읽고 다시 디코드한다. 워커가 직렬이라 그 낭비가 **뒤에 선 모든
    /// 조회를 밀기까지** 한다. 순정은 디코드 직전에 메모리를 다시 본다
    /// (`SDImageCache.m` — "Special case: If user query image in list for the same URL").
    func testDuplicateQueryDecodesOnce() throws {
        try seed("dup")
        let coder = CountingDecodeCoder()
        SDImageCodersManager.shared.addCoder(coder)

        let both = expectation(description: "both")
        both.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            _ = cache.queryImage(forKey: "dup", options: [], context: nil,
                                 cacheType: .all) { _, _, _ in both.fulfill() }
        }
        wait(for: [both], timeout: 5)

        XCTAssertEqual(coder.calls.withLock { $0 }, 1,
                       "같은 키를 두 번 디코드했다 — 직렬 워커에선 뒤에 선 조회까지 밀린다")
    }

    /// **만료 정리와 디스크 I/O 는 같은 줄에 서야 한다.**
    ///
    /// `SDDiskCache` 는 자체 `NSFileManager` 인스턴스를 쓰고, 그건 스레드마다 하나가
    /// 원칙이다. 정리를 다른 스레드에서 돌리면 쓰기·읽기와 겹치고, 원자적 쓰기를
    /// 꺼둔 상태(`diskCacheWritingOptions = []`)라 그 겹침이 더 나쁘다.
    ///
    /// 직렬이면 정리 뒤에 넣은 조회가 정리 결과를 **반드시** 본다.
    func testPurgeIsSerializedWithDiskAccess() throws {
        try seed("expiring")
        config.maxDiskAge = 0
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        cache.purgeExpiredData(completion: nil)      // 완료를 기다리지 않는다
        let probed = expectation(description: "probed")
        let found = OSAllocatedUnfairLock(initialState: SDImageCacheType.memory)
        cache.containsImage(forKey: "expiring", cacheType: .disk) { type in
            found.withLock { $0 = type }
            probed.fulfill()
        }
        wait(for: [probed], timeout: 5)

        XCTAssertEqual(found.withLock { $0 }, SDImageCacheType.none,
                       "정리와 조회가 다른 줄에 서 있다 — 같은 파일을 동시에 만질 수 있다")
    }
}

/// 생명주기 정리의 **실행 보장**.
///
/// 정리는 이 캐시의 유일한 만료·용량 집행 경로라, "언젠가 돌겠지" 로는 부족하다.
/// 백그라운드에서 중간에 멈추면 다음 포그라운드의 첫 조회들이 그 뒤에 줄 서고
/// (시작 시점 정리를 없애며 고쳤던 정체가 복귀 시점으로 옮겨온다), 종료에서 안
/// 돌면 캡이 영영 집행되지 않는다.
@MainActor
final class ThreadedImageCacheLifecycleTests: XCTestCase {

    private final class SlowCoder: NSObject, SDImageCoder, @unchecked Sendable {
        func canDecode(from data: Data?) -> Bool {
            Thread.sleep(forTimeInterval: 0.4)
            return false
        }
        func decodedImage(with data: Data?, options: [SDImageCoderOption: Any]?) -> UIImage? { nil }
        func canEncode(to format: SDImageFormat) -> Bool { false }
        func encodedData(with image: UIImage?, format: SDImageFormat,
                         options: [SDImageCoderOption: Any]?) -> Data? { nil }
    }

    private var cache: ThreadedImageCache!
    private var originalCoders: [any SDImageCoder] = []

    override func setUp() {
        super.setUp()
        cache = ThreadedImageCache(cacheDirectory: NSTemporaryDirectory()
            .appending("nunting-life-\(UUID().uuidString)"))
        originalCoders = SDImageCodersManager.shared.coders ?? []
    }

    override func tearDown() {
        SDImageCodersManager.shared.coders = originalCoders
        cache = nil
        super.tearDown()
    }

    /// **종료 정리는 기다린다.** 비동기로 넣기만 하면 프로세스가 먼저 죽어 안 돈다.
    /// 워커를 0.4초 붙잡아 두고, 정리 호출이 그만큼 실제로 기다리는지 본다.
    func testTerminatePurgeWaitsForTheWorker() throws {
        let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            .image { _ in }.pngData())
        let stored = expectation(description: "stored")
        cache.store(nil, imageData: data, forKey: "k", cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        SDImageCodersManager.shared.addCoder(SlowCoder())
        _ = cache.queryImage(forKey: "k", options: [], context: nil, cacheType: .disk) { _, _, _ in }

        let startedAt = Date()
        cache.purgeExpiredDataSynchronously()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertGreaterThan(elapsed, 0.3,
                             "정리가 워커를 안 기다렸다 — 종료 시엔 그대로 유실된다")
    }

    /// **백그라운드 정리는 배경 작업 창 안에서 돈다.** 창이 없으면 정리 도중
    /// suspend 돼 다음 포그라운드의 첫 조회들이 밀린다.
    func testBackgroundPurgeOpensABackgroundTaskWindow() {
        let window = ImageCachePurgeWindow.shared
        let originalBegin = window.beginTask
        let originalEnd = window.endTask
        defer {
            window.beginTask = originalBegin
            window.endTask = originalEnd
        }
        var opened = 0
        var closed = 0
        window.beginTask = { _ in
            opened += 1
            return UIBackgroundTaskIdentifier(rawValue: 7)
        }
        window.endTask = { _ in closed += 1 }

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification,
                                        object: nil)
        // 정리 완료는 메인 큐로 돌아온다 — 런루프를 돌려 받는다.
        let deadline = Date(timeIntervalSinceNow: 3)
        while closed == 0, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }

        XCTAssertGreaterThan(opened, 0, "배경 작업 창을 안 열었다")
        XCTAssertGreaterThan(closed, 0, "배경 작업 창을 안 닫았다 — 안 닫으면 앱이 강제 종료된다")
    }
}
