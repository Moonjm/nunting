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

    // MARK: - fit 크기 (줌 대상 뷰 = fit 된 이미지)

    /// 줌 대상 imageView 는 뷰포트가 아니라 "fit 된 이미지" 크기여야 한다 —
    /// 뷰포트 크기 뷰를 확대하면 레터박스까지 콘텐츠가 돼 이미지 밖 여백을
    /// 한없이 패닝하게 된다(Codex P2).
    func testFittedSize() {
        let tall = ImageViewer.fittedSize(
            imageSize: CGSize(width: 669, height: 25809),
            viewportSize: CGSize(width: 402, height: 852))
        XCTAssertEqual(tall.height, 852, accuracy: 0.5)
        XCTAssertEqual(tall.width, 852 * 669 / 25809, accuracy: 0.5)

        let landscape = ImageViewer.fittedSize(
            imageSize: CGSize(width: 4000, height: 3000),
            viewportSize: CGSize(width: 402, height: 852))
        XCTAssertEqual(landscape, CGSize(width: 402, height: 301.5))
    }

    /// 1차 → 2차(화질만) 교체 판별 — aspect 가 같아 fit 크기가 일치하면
    /// 줌/오프셋을 보존한 채 이미지만 갈아끼운다(읽던 위치 유지, Codex P2).
    func testSameFittedSizeDetectsQualitySwap() {
        XCTAssertTrue(ImageViewer.isSameFittedSize(
            CGSize(width: 22.09, height: 852), CGSize(width: 22.4, height: 852)))
        XCTAssertFalse(ImageViewer.isSameFittedSize(
            CGSize(width: 402, height: 301), CGSize(width: 22, height: 852)))
    }

    // MARK: - 더블탭 줌 대상 rect (imageView = fit 이미지 좌표계)

    /// 레터박스 탭은 imageView 좌표에서 이미지 밖(음수/초과)으로 들어온다 —
    /// 줌 rect 가 이미지 위로 클램프되어야 여백으로 확대되지 않는다.
    func testDoubleTapInLetterboxClampsToImageStrip() {
        let fitted = CGSize(width: 22.09, height: 852) // 669×25809 fit
        let rect = ImageViewer.doubleTapZoomRect(
            tapPoint: CGPoint(x: -160, y: 400), // 왼쪽 여백 탭(이미지 좌표 기준 음수)
            fittedImageSize: fitted,
            viewportSize: CGSize(width: 402, height: 852),
            targetScale: 18)
        XCTAssertEqual(rect.midX, fitted.width / 2, accuracy: 1.0,
                       "가로는 rect 가 띠보다 넓어 이미지 중심으로 폴백")
        XCTAssertEqual(rect.midY, 400, accuracy: 1.0, "세로 탭 위치는 유지")
    }

    func testDoubleTapOnNormalImageKeepsTapCenterOnFittingAxis() {
        // fit 402×301.5 이미지: 가로는 2.5× rect(160.8)가 들어가므로 탭 x 유지,
        // 세로는 rect(340.8)가 이미지보다 커서 이미지 중심(150.75) 폴백.
        let rect = ImageViewer.doubleTapZoomRect(
            tapPoint: CGPoint(x: 100, y: 200),
            fittedImageSize: CGSize(width: 402, height: 301.5),
            viewportSize: CGSize(width: 402, height: 852),
            targetScale: 2.5)
        XCTAssertEqual(rect.midX, 100, accuracy: 1.0)
        XCTAssertEqual(rect.midY, 150.75, accuracy: 1.0)
    }

    func testZoomScaleHardCap() {
        // 병리적 세로비라도 상한 60 — UIScrollView 줌 폭주 방지.
        let z = ImageViewer.maxZoomScale(
            imageSize: CGSize(width: 100, height: 50000),
            viewSize: CGSize(width: 402, height: 852))
        XCTAssertLessThanOrEqual(z, 60)
    }
}
