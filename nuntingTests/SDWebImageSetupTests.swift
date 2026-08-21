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

    /// 다운로드 슬롯 폭. 지금은 재실험의 B 조건(8)이다 — 1차 실험은 가벼운
    /// 워크로드에서 비교해 판정이 무효였고, 무거운 글에서 재현한 A 조건(4)의
    /// 대기 p90 이 4,459ms 로 확인됐다. 근거와 판정 기준은 `SDWebImageSetup` 주석.
    /// 실험이 끝나면 이 값은 결론에 맞춰 확정된다.
    func testConfigureUsesExperimentDownloadSlotWidth() {
        SDWebImageSetup.configure()

        XCTAssertEqual(SDWebImageDownloader.shared.config.maxConcurrentDownloads, 8)
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
