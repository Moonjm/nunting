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

    override func setUp() {
        super.setUp()
        cache = ThreadedImageCache(cacheDirectory: NSTemporaryDirectory()
            .appending("nunting-test-\(UUID().uuidString)"))
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

    /// **데이터 없이 이미지만 들어오는 저장**도 디스크에 남아야 한다.
    ///
    /// 이 경로가 드문 게 아니라 본문 이미지의 **정상 경로**다. 우리는 거의 모든
    /// 본문 이미지에 `imageThumbnailPixelSize` 를 걸고, SDWebImage 는 썸네일을
    /// 저장할 때 원본 데이터를 일부러 버린다(`SDWebImageManager.m` —
    /// `if (isThumbnail) { cacheData = nil; }`). 순정 `SDImageCache` 는 그때
    /// 이미지를 인코딩해서 쓴다(`SDImageCache.m:272-306`).
    ///
    /// 우리가 그냥 버리면 썸네일 키 엔트리가 영영 안 생긴다. 증상은 안 보인다 —
    /// 매니저가 원본 키로 폴백해 그림은 나오기 때문이다. 대신 재방문마다 원본
    /// 전체를 다시 디코드한다. 정확히 "조용한 무효화" 의 모양이라 테스트로 못 박는다.
    func testStoresImageWithoutDataToDisk() {
        let stored = expectation(description: "stored")
        cache.store(sampleImage(), imageData: nil, forKey: "encoded",
                    cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        let queried = expectation(description: "queried")
        let result = OSAllocatedUnfairLock<(UIImage?, SDImageCacheType)>(initialState: (nil, .none))
        _ = cache.queryImage(forKey: "encoded", options: [], context: nil,
                             cacheType: .disk) { image, _, type in
            result.withLock { $0 = (image, type) }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 5)

        let (image, type) = result.withLock { $0 }
        XCTAssertNotNil(image, "이미지만 준 저장이 디스크에서 사라졌다")
        XCTAssertEqual(type, .disk)
    }

    /// **실제 파이프라인 확인**: 썸네일 컨텍스트로 로드하면 썸네일 키 엔트리가
    /// 디스크에 남는가.
    ///
    /// 본문 이미지는 거의 전부 `imageThumbnailPixelSize` 를 달고 로드된다. 그때
    /// SDWebImage 는 썸네일 저장에 원본 데이터를 넘기지 않고
    /// (`SDWebImageManager.m` — `if (isThumbnail) { cacheData = nil; }`) 캐시가
    /// 알아서 인코딩해 쓰기를 기대한다(`SDImageCache.m:272-306`).
    ///
    /// 안 쓰면 증상이 안 보인다 — 매니저가 원본 키로 폴백해 그림은 나온다. 대신
    /// 재방문마다 조회가 두 번 돌고(썸네일 미스 → 원본 히트) 원본 전체를 다시
    /// 다운샘플한다. 네트워크 없이 원본만 시드해 이 경로 전체를 돌린다.
    func testThumbnailLoadLeavesThumbnailEntryOnDisk() throws {
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

        // 저장은 표시 뒤 비동기로 끝난다 — 디스크에 도달할 때까지 짧게 폴링한다.
        var found = SDImageCacheType.none
        for _ in 0..<40 {
            let probed = expectation(description: "probe")
            cache.containsImage(forKey: thumbnailKey, cacheType: .disk) { type in
                found = type
                probed.fulfill()
            }
            wait(for: [probed], timeout: 5)
            if found == .disk { break }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        XCTAssertEqual(found, .disk, "썸네일 키 엔트리가 디스크에 안 남았다 — 재방문이 매번 원본 재디코드가 된다")
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

    /// **이 클래스의 존재 이유**: 디스크 작업이 libdispatch 풀 스레드에서 돌면 안 된다.
    /// 풀 스레드를 쓰면 지금 겪는 고갈이 그대로 재현되므로, 전용 스레드에서 도는지를
    /// 직접 확인한다.
    func testDiskWorkRunsOffTheDispatchPool() throws {
        let data = try pngData()
        let stored = expectation(description: "stored")
        cache.store(sampleImage(), imageData: data, forKey: "thread",
                    cacheType: .disk) { stored.fulfill() }
        wait(for: [stored], timeout: 5)

        let queried = expectation(description: "queried")
        let threadName = OSAllocatedUnfairLock(initialState: "")
        _ = cache.queryImage(forKey: "thread", options: [], context: nil, cacheType: .disk) { _, _, _ in
            threadName.withLock { $0 = Thread.current.name ?? "" }
            queried.fulfill()
        }
        wait(for: [queried], timeout: 5)

        XCTAssertEqual(threadName.withLock { $0 }, ThreadedImageCache.workerThreadName,
                       "디스크 조회가 전용 스레드가 아닌 곳에서 돌았다")
    }
}
