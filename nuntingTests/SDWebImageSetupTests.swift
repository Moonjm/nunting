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

    /// 다운로드 슬롯 폭. SDWebImage 는 디코드를 **다운로드 오퍼레이션 안에서** 돌리고
    /// `done` 은 그 뒤 barrier 라(SDWebImageDownloaderOperation.m:363-425) 슬롯은
    /// 다운로드가 아니라 다운로드+디코드 동안 잡혀 있다. 기기 계측(2026-08-21)에서
    /// 다운로드가 19~37ms 로 끝난 etoland 배치에서도 슬롯 대기가 1.2~1.5s 쌓였다 —
    /// 슬롯을 붙잡은 건 앞 이미지의 디코드(webpStatic p50 82ms/max 426ms)다.
    /// 값이 조용히 되돌아가면 그 대기가 그대로 돌아오므로 테스트로 못 박는다.
    func testConfigureWidensDownloadPipelineForDecodeBoundSlots() {
        SDWebImageSetup.configure()

        XCTAssertEqual(SDWebImageDownloader.shared.config.maxConcurrentDownloads, 8)
    }
}
