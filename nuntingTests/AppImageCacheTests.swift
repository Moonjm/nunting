import XCTest
import os
import SDWebImage
@testable import nunting

/// `AppImageCache` — 디스크 쓰기를 **보는 동안엔 미루는** 캐시.
///
/// 왜: 이미지가 쏟아지는 동안 34장을 `ioQueue`(직렬)에서 순차로 디스크에 쓰는데, 그
/// 스레드가 I/O 에 묶여 백그라운드 풀이 고갈되고 디코드 블록이 순서를 기다린다.
/// 디스크 쓰기만 없앤 세션에서 본문 show p90 이 5,049ms → 383ms(13배)로 무너졌다.
/// 쓰기 비용을 절반으로 줄이는 것(atomic 해제)으로는 안 됐다 — 크기가 아니라 **쓰기가
/// 스레드를 붙잡는다는 사실 자체**가 문제라, 시점을 옮긴다.
///
/// 실제 디스크로 검증한다. 이 클래스의 계약이 "디스크에 언제 쓰이는가" 라서, 그걸
/// 스텁으로 확인하면 아무것도 확인하지 않는 것과 같다.
final class AppImageCacheTests: XCTestCase {

    private var cache: AppImageCache!
    private var namespace: String!

    override func setUp() {
        super.setUp()
        // 테스트마다 고유 네임스페이스 — 실제 캐시 디렉터리를 안 건드린다.
        namespace = "test-\(UUID().uuidString)"
        cache = AppImageCache(namespace: namespace, quietWindow: 60, maxPendingBytes: 1 << 20)
    }

    override func tearDown() {
        cache.clear(with: .all, completion: nil)
        cache = nil
        super.tearDown()
    }

    private func sampleImage() -> UIImage {
        UIGraphicsBeginImageContext(CGSize(width: 4, height: 4))
        defer { UIGraphicsEndImageContext() }
        return UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
    }

    private func diskContains(_ key: String) -> Bool {
        let exp = expectation(description: "contains")
        let found = OSAllocatedUnfairLock(initialState: false)
        cache.containsImage(forKey: key, cacheType: .disk) { type in
            found.withLock { $0 = (type == .disk) }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 3)
        return found.withLock { $0 }
    }

    /// 저장 요청 시점에는 디스크에 안 쓴다 — 그게 이 클래스의 존재 이유다.
    func testDefersDiskWriteUntilFlush() {
        let key = "deferred"
        cache.store(sampleImage(), imageData: Data([1, 2, 3, 4]), forKey: key,
                    cacheType: .all, completion: nil)

        XCTAssertFalse(diskContains(key), "요청 즉시 디스크에 쓰이면 미루는 의미가 없다")

        let flushed = expectation(description: "flushed")
        cache.flushPendingDiskWrites { flushed.fulfill() }
        wait(for: [flushed], timeout: 3)

        XCTAssertTrue(diskContains(key), "flush 후에는 디스크에 있어야 한다")
    }

    /// 메모리에는 **즉시** 들어가야 한다. 미루는 건 디스크뿐이고, 메모리까지 미루면
    /// 방금 받은 이미지를 다시 디코드하게 된다.
    func testStoresToMemoryImmediately() {
        cache.store(sampleImage(), imageData: Data([1, 2, 3, 4]), forKey: "mem",
                    cacheType: .all, completion: nil)

        XCTAssertNotNil(cache.imageFromMemoryCache(forKey: "mem"))
    }

    /// 대기분이 상한을 넘으면 바로 쓴다. 안 그러면 미룬 데이터가 메모리에 쌓여
    /// OOM 이력이 있는 앱에서 위험을 다른 곳으로 옮기는 셈이 된다.
    func testFlushesWhenPendingExceedsByteCap() {
        let small = AppImageCache(namespace: "test-cap-\(UUID().uuidString)",
                                  quietWindow: 60, maxPendingBytes: 8)
        defer { small.clear(with: .all, completion: nil) }

        small.store(sampleImage(), imageData: Data(repeating: 0, count: 16),
                    forKey: "big", cacheType: .all, completion: nil)

        // 상한 초과 → 즉시 flush 가 걸리므로 잠시 뒤 디스크에 있어야 한다.
        let exp = expectation(description: "auto flushed")
        let found = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            small.containsImage(forKey: "big", cacheType: .disk) { type in
                found.withLock { $0 = (type == .disk) }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(found.withLock { $0 }, "상한을 넘겨도 안 쓰면 대기분이 무한정 쌓인다")
    }

    /// 디스크만 지정한 저장도 미룬다(메모리 저장 없이).
    func testDefersDiskOnlyStore() {
        cache.store(sampleImage(), imageData: Data([9, 9]), forKey: "diskonly",
                    cacheType: .disk, completion: nil)

        XCTAssertFalse(diskContains("diskonly"))

        let flushed = expectation(description: "flushed")
        cache.flushPendingDiskWrites { flushed.fulfill() }
        wait(for: [flushed], timeout: 3)

        XCTAssertTrue(diskContains("diskonly"))
    }
}
