import XCTest
@testable import nunting

/// 전체화면 뷰어의 극단 세로 이미지(웹툰형 aagag 이슈 짤) 지원 계약.
///
/// 종전엔 4096 정사각 박스 디코드라 800×24000 이 137×4096 으로 뭉개졌고
/// (인라인보다도 흐림), aspectFit + 최대 줌 5×로는 폭 ~28pt 표시를 140pt
/// 까지밖에 못 키워 "확대가 중간에 끝나 읽을 수 없는" 상태였다.
/// - 2차 tall 재디코드: 1차(정사각) 결과가 높이 캡에 닿은 극단 세로형이면
///   버짓(20MP) 박스로 다시 디코드 — 통상 케이스(800×24000)는 native 폭.
/// - 동적 max zoom: 폭맞춤 배율 ×2 까지 허용해 세로 리더처럼 읽을 수 있게.
final class ImageViewerTallImageTests: XCTestCase {

    // MARK: - 2차 재디코드 판별

    func testCappedTallFirstPassNeedsRedecode() {
        // 1차 박스(4096) 높이에 닿았고 극단 세로형(폭/높이 < 1/4) → 재디코드.
        XCTAssertTrue(ImageViewer.needsTallRedecode(
            decodedPixels: CGSize(width: 137, height: 4096), firstPassBoxEdge: 4096))
    }

    func testModerateAspectDoesNotRedecode() {
        // 세로형이지만 1/4 이내(일반 인물/문서 사진) — 정사각 박스로 충분.
        XCTAssertFalse(ImageViewer.needsTallRedecode(
            decodedPixels: CGSize(width: 2000, height: 4096), firstPassBoxEdge: 4096))
    }

    func testUncappedTallDoesNotRedecode() {
        // 높이가 박스에 안 닿음 = 원본이 그보다 작아 native 디코드된 것 — 재디코드 불필요.
        XCTAssertFalse(ImageViewer.needsTallRedecode(
            decodedPixels: CGSize(width: 300, height: 3000), firstPassBoxEdge: 4096))
    }

    // MARK: - tall 재디코드 박스

    func testTallBoxDecodesNearNativeWidthWithinBudget() {
        // 800×24000(aspect 1/30): 버짓 20MP → 폭 ≈ sqrt(20e6/30) ≈ 816 —
        // 원본 폭(800)을 native 로 통과시킬 만큼. 높이는 hard max(24576) 안.
        let box = ImageViewer.tallDecodeBoxPixels(aspect: 1.0 / 30.0, displayScale: 3)
        XCTAssertEqual(box.width, (20_000_000.0 / 30.0).squareRoot(), accuracy: 1.0)
        XCTAssertLessThanOrEqual(box.height, 24_576)
        XCTAssertLessThanOrEqual(box.width * box.height, 20_000_000 * 1.01,
                                 "총픽셀 버짓(20MP ≈ 80MB, 뷰어 단일 이미지) 준수")
    }

    // MARK: - 동적 max zoom

    func testTallImageZoomsToReadableWidth() {
        // 546×16384 이미지를 402×852 뷰에 aspectFit 하면 폭 ~21pt — 폭맞춤까지
        // 필요한 배율(≈14×)의 2배를 허용해야 읽기 배율에 도달한다.
        let z = ImageViewer.maxZoomScale(
            imageSize: CGSize(width: 546, height: 16384),
            viewSize: CGSize(width: 402, height: 852))
        XCTAssertEqual(z, (402.0 / 546.0) / min(402.0 / 546.0, 852.0 / 16384.0) * 2, accuracy: 0.1)
        XCTAssertGreaterThan(z, 20)
    }

    func testNormalImageKeepsLegacyZoomRange() {
        // 일반 사진은 종전 최대 5× 유지.
        let z = ImageViewer.maxZoomScale(
            imageSize: CGSize(width: 4000, height: 3000),
            viewSize: CGSize(width: 402, height: 852))
        XCTAssertEqual(z, 5)
    }

    func testZoomScaleHardCap() {
        // 병리적 세로비라도 상한 60 — UIScrollView 줌 폭주 방지.
        let z = ImageViewer.maxZoomScale(
            imageSize: CGSize(width: 100, height: 50000),
            viewSize: CGSize(width: 402, height: 852))
        XCTAssertLessThanOrEqual(z, 60)
    }
}
