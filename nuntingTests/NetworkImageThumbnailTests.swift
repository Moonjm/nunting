import XCTest
import SDWebImage
@testable import nunting

/// `NetworkImage` 의 다운샘플 박스 매핑 계약.
///
/// 본문 사진은 그동안 풀사이즈 디코드였다 — 정사각 thumbnail 캡이 aagag
/// 세로 패널(800×6000)의 긴 변을 깎아 뭉개버리기 때문. 비정방 박스(폭만
/// 화면폭 px, 높이 사실상 무제한)는 세로 패널을 무손실 통과시키면서
/// 일반 대형 사진(4000×3000)만 화면폭으로 다운샘플한다.
final class NetworkImageThumbnailTests: XCTestCase {
    func testSquareCapKeepsLegacyBehavior() {
        let ctx = NetworkImage.thumbnailContext(maxPointSize: 100, maxPointWidth: nil, scale: 3)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size, CGSize(width: 300, height: 300), "기존 정사각 캡: 포인트×스케일")
    }

    func testWidthOnlyBoxCapsWidthButNotHeight() {
        let ctx = NetworkImage.thumbnailContext(maxPointSize: nil, maxPointWidth: 393, scale: 3)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size?.width, 1179, "폭 = 화면폭 pt × scale")
        XCTAssertGreaterThanOrEqual(size?.height ?? 0, 30000,
            "높이는 사실상 무제한이어야 함 — 세로 패널(수만 px)이 높이 캡에 걸려 폭까지 깎이면 안 됨")
    }

    func testSquareCapWinsWhenBothSet() {
        // 기존 호출부(아이콘/스티커/포스터) 보호 — 정사각 캡이 우선.
        let ctx = NetworkImage.thumbnailContext(maxPointSize: 100, maxPointWidth: 393, scale: 2)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size, CGSize(width: 200, height: 200))
    }

    func testNoCapsReturnsNilContext() {
        XCTAssertNil(NetworkImage.thumbnailContext(maxPointSize: nil, maxPointWidth: nil, scale: 3),
                     "캡 없음 = 네이티브 해상도 디코드 (context 자체가 nil)")
    }
}
