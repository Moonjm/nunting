import XCTest
import os
import SDWebImage
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
