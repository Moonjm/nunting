import XCTest
import SDWebImage
@testable import nunting

// @MainActor: SDWebImageSetup.configure() 가 main actor 소속(앱 시작 시 설정).
@MainActor
final class SDWebImageSetupTests: XCTestCase {
    func testConfigureRegistersSingleSignpostWebPCoderAtHighestPriority() {
        let manager = SDImageCodersManager.shared
        let originalCoders = manager.coders ?? []
        manager.coders = originalCoders.filter { !($0 is SignpostWebPCoder) }
        defer { manager.coders = originalCoders }

        SDWebImageSetup.configure()
        SDWebImageSetup.configure()

        let signpostCoders = (manager.coders ?? []).filter { $0 is SignpostWebPCoder }
        XCTAssertEqual(signpostCoders.count, 1)
        XCTAssertTrue(manager.coders?.last is SignpostWebPCoder)
    }

    /// 다운로드 슬롯 폭 4. 8 로 넓히는 실험을 **두 번** 했고 둘 다 폭이 병목이
    /// 아님을 보였다 — 같은 글·같은 콜드 조건에서 대기 p90 4,590ms vs 4,356ms
    /// (2배로 늘려도 그대로), 본문 show 는 오히려 악화. 근거 숫자는
    /// `SDWebImageSetup` 주석에 표로 남겼다.
    func testConfigureKeepsMeasuredDownloadSlotWidth() {
        SDWebImageSetup.configure()

        XCTAssertEqual(SDWebImageDownloader.shared.config.maxConcurrentDownloads, 4)
    }

    /// 동시 큐 attr 을 실제로 찾아낸다. Swift 에는 `DISPATCH_QUEUE_CONCURRENT` 가
    /// 열려 있지 않아(`_dispatch_queue_attr_concurrent` 는 불완전 타입이라 참조 불가)
    /// 심볼 주소로 얻는다. C 에서 매크로 값과 `dlsym` 결과가 같은 주소임을 확인했고,
    /// 여기서는 "nil 이 아니고, 그 attr 로 만든 큐가 진짜 동시 실행되는지" 를 본다 —
    /// 엉뚱한 심볼을 잡으면 조용히 직렬로 돌아가므로 값 존재만으로는 부족하다.
    func testConcurrentQueueAttributeIsResolvedAndActuallyConcurrent() throws {
        let attr = try XCTUnwrap(SDWebImageSetup.concurrentQueueAttribute(),
                                 "동시 큐 attr 심볼을 못 찾음")

        // attr 로 만든 큐에서 두 블록이 겹쳐 실행돼야 한다. 직렬이면 첫 블록이
        // 두 번째를 기다리며 영원히 안 끝난다(타임아웃으로 실패).
        let queue = SDWebImageSetup.makeQueue(label: "test.concurrency", attr: attr)
        let started = expectation(description: "second block runs while first waits")
        let release = DispatchSemaphore(value: 0)
        queue.async {
            _ = release.wait(timeout: .now() + 2)
        }
        queue.async {
            started.fulfill()
            release.signal()
        }

        wait(for: [started], timeout: 2)
    }

    /// 캐시 IO 큐를 동시 큐로 세운다. 이 설정은 **캐시 생성 시점에 한 번만** 읽히고
    /// 그 뒤 바꾸면 조용히 무효라(`SDImageCacheConfig.h`), 값이 되돌아가거나 설정
    /// 자체가 빠지면 아무 신호 없이 직렬로 돌아간다. 그래서 값을 못 박는다.
    func testConfigureMakesCacheIOQueueConcurrent() {
        SDWebImageSetup.configure()

        XCTAssertNotNil(SDImageCacheConfig.default.ioQueueAttributes)
        XCTAssertTrue(
            SDImageCacheConfig.default.ioQueueAttributes === SDWebImageSetup.concurrentQueueAttribute(),
            "IO 큐 attr 이 동시 큐가 아니다 — 캐시 조회/디코드가 직렬로 돌아간다")
    }



    /// JPEG/PNG 디코드도 계측돼야 한다. WebP 만 재던 동안 디코드 이벤트가 net 이벤트의
    /// 1/5 밖에 안 잡혀(94 vs 495) "디코드 비용은 작다" 는 판단의 근거가 반쪽이었다.
    func testConfigureRegistersSingleSignpostIOCoderAtHighPriority() {
        let manager = SDImageCodersManager.shared
        let originalCoders = manager.coders ?? []
        manager.coders = originalCoders.filter { !($0 is SignpostIOCoder) }
        defer { manager.coders = originalCoders }

        SDWebImageSetup.configure()
        SDWebImageSetup.configure()

        XCTAssertEqual((manager.coders ?? []).filter { $0 is SignpostIOCoder }.count, 1)
    }
}
