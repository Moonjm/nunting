import XCTest
import SDWebImage
@testable import nunting

/// `NetworkImage` 의 다운샘플 박스 매핑 계약.
///
/// 본문 사진은 그동안 풀사이즈 디코드였다 — 정사각 thumbnail 캡이 aagag
/// 세로 패널(800×6000)의 긴 변을 깎아 뭉개버리기 때문. 비정방 박스(폭만
/// 화면폭 px, 높이는 넉넉한 캡)는 통상 세로 패널을 무손실 통과시키면서
/// 일반 대형 사진(4000×3000)은 화면폭으로, 초대형 패널(수만 px)은 높이
/// 캡으로 다운샘플한다 — 무제한 높이는 30MP 풀 디코드(메모리 스파이크 +
/// ImageIO 락 hang)를 그대로 통과시켰다.
final class NetworkImageThumbnailTests: XCTestCase {
    func testSquareCapKeepsLegacyBehavior() {
        let ctx = NetworkImage.thumbnailContext(maxPointSize: 100, maxPointWidth: nil, scale: 3)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size, CGSize(width: 300, height: 300), "기존 정사각 캡: 포인트×스케일")
    }

    func testWidthOnlyBoxCapsWidthAndTallHeight() {
        let ctx = NetworkImage.thumbnailContext(maxPointSize: nil, maxPointWidth: 393, scale: 3)
        let size = (ctx?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(size?.width, 1179, "폭 = 화면폭 pt × scale")
        XCTAssertEqual(size?.height, NetworkImage.tallImageMaxPixelHeight,
            "높이 캡 = 통상 세로 패널(800×6000)은 무손실 통과할 만큼 넉넉하되, 수만 px 패널의 풀 디코드는 차단")
        XCTAssertGreaterThanOrEqual(size?.height ?? 0, 6000,
            "문서화된 aagag 세로 패널(800×6000)이 높이 캡에 걸려 폭까지 깎이면 안 됨")
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
