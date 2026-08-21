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

    /// 다운로드 슬롯 폭 4. 8 로 넓히는 실험을 했고 **반증됐다** — 기기 계측에서
    /// 대기 분포가 그대로였고(>100ms 14% 동일, >500ms 8% 동일) 메모리 피크만
    /// 433MB → 577MB 로 올랐다. 폭이 병목이면 2배에서 대기가 내려갔어야 한다.
    /// 근거는 `SDWebImageSetup` 주석에 숫자로 남아 있다. 값이 조용히 다시
    /// 올라가지 않게 못 박는다.
    func testConfigureKeepsDownloadSlotsAtMeasuredWidth() {
        SDWebImageSetup.configure()

        XCTAssertEqual(SDWebImageDownloader.shared.config.maxConcurrentDownloads, 4)
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
