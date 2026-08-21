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


    /// 캐시 IO 큐는 **라이브러리 기본(직렬)** 을 유지한다. 동시 큐로 바꾸는 실험을
    /// 했고 대기 p50 이 343ms → 2,173ms 로 6배 악화됐다(근거 표는 `SDWebImageSetup`
    /// 주석). 병렬도를 올리는 방향이 이 파이프라인에서 안 통한다는 세 번째 확인이라,
    /// 누가 이 설정을 다시 건드리면 여기서 걸리게 한다.
    func testConfigureLeavesCacheIOQueueAtLibraryDefault() {
        let pristine = SDImageCacheConfig()

        SDWebImageSetup.configure()

        XCTAssertTrue(SDImageCacheConfig.default.ioQueueAttributes === pristine.ioQueueAttributes,
                      "IO 큐 attr 이 라이브러리 기본에서 바뀌었다 — 측정상 더 느려진 방향이다")
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
