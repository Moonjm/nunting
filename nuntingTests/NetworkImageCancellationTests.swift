import XCTest
import SDWebImage
@testable import nunting

/// 취소(2002/-999)를 영구 실패("다시 시도")로 승격하지 않는 계약.
///
/// 실측 버그: aagag 첫 진입에서 본문 이미지 로드가 캐시 조회 중 취소
/// (`SDWebImageErrorDomain#2002`)됐는데, onFailure 가 이를 failed 로
/// 승격 → retry UI 전환 → AnimatedImage 가 뷰에서 제거되며 후속 로드도
/// dismantle-취소 → "다시 시도" 고착. 취소는 뷰 교체/재시도 경합의
/// 정상 신호이므로 무시해야 한다(다음 updateUIView 가 자동 재로드).
final class NetworkImageCancellationTests: XCTestCase {
    func testSDCancelledIsNotAFailure() {
        let error = NSError(
            domain: SDWebImageErrorDomain,
            code: SDWebImageError.cancelled.rawValue,
            userInfo: nil
        )
        XCTAssertTrue(NetworkImage.isCancellation(error))
    }

    func testURLCancelledIsNotAFailure() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        XCTAssertTrue(NetworkImage.isCancellation(error))
    }

    func testRealFailuresStillSurface() {
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        XCTAssertFalse(NetworkImage.isCancellation(timeout), "타임아웃은 진짜 실패 — retry UI 필요")
        let badData = NSError(
            domain: SDWebImageErrorDomain,
            code: SDWebImageError.badImageData.rawValue,
            userInfo: nil
        )
        XCTAssertFalse(NetworkImage.isCancellation(badData))
    }
}
