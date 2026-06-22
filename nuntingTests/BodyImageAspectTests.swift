import XCTest
@testable import nunting

/// 본문 `<img>` 의 선언된 종횡비(width/height)를 디코드 없이 마크업에서
/// 뽑는 계약. 인벤은 `style="… aspect-ratio: 1366 / 768; …"` 형식으로
/// 크기를 주므로, 이를 파싱해 placeholder 높이를 핀하고(동시 디코드 throttle)
/// off-screen release 가드(`effectiveAspect != nil`)를 통과시킨다.
final class BodyImageAspectTests: XCTestCase {

    func testParsesCSSAspectRatio() {
        // 인벤 실제 마크업
        let aspect = ParserBlockWalker.declaredAspectRatio(
            style: "font-size: 15px; width: 800px; aspect-ratio: 1366 / 768; max-width: 100%;",
            width: "",
            height: ""
        )
        XCTAssertEqual(aspect ?? 0, 1366.0 / 768.0, accuracy: 0.001,
                       "style 의 aspect-ratio: W / H 를 그대로 사용")
    }

    func testFallsBackToWidthHeightAttributes() {
        let aspect = ParserBlockWalker.declaredAspectRatio(style: "", width: "800", height: "600")
        XCTAssertEqual(aspect ?? 0, 800.0 / 600.0, accuracy: 0.001,
                       "aspect-ratio 없으면 width/height 속성으로")
    }

    func testFallsBackToStylePixelDimensions() {
        let aspect = ParserBlockWalker.declaredAspectRatio(
            style: "width: 710px; height: 482px;", width: "", height: ""
        )
        XCTAssertEqual(aspect ?? 0, 710.0 / 482.0, accuracy: 0.001,
                       "aspect-ratio·속성 없으면 style 의 px width/height 로")
    }

    func testCSSAspectRatioWinsOverAttributes() {
        let aspect = ParserBlockWalker.declaredAspectRatio(
            style: "aspect-ratio: 2 / 1;", width: "800", height: "600"
        )
        XCTAssertEqual(aspect ?? 0, 2.0, accuracy: 0.001, "aspect-ratio 가 속성보다 우선")
    }

    func testReturnsNilWhenNoDimensions() {
        XCTAssertNil(ParserBlockWalker.declaredAspectRatio(
            style: "color: red; max-width: 100%;", width: "", height: ""
        ), "크기 정보 없으면 nil (→ NetworkImage fallback 으로)")
    }

    func testReturnsNilForZeroOrMalformed() {
        XCTAssertNil(ParserBlockWalker.declaredAspectRatio(style: "aspect-ratio: 0 / 0;", width: "", height: ""),
                     "0 비율은 무의미 → nil")
        XCTAssertNil(ParserBlockWalker.declaredAspectRatio(style: "aspect-ratio: abc;", width: "x", height: "y"),
                     "파싱 불가 → nil")
    }

    // MARK: - NetworkImage.effectiveAspect 우선순위

    func testEffectiveAspectPrefersParserValue() {
        // 파서 실제값이 있으면 measured/fallback 무시 (Clien/인벤 정확 경로).
        let a = NetworkImage.effectiveAspect(aspectRatio: 1.5, measuredAspect: 0.8, fallbackAspect: 1.0)
        XCTAssertEqual(a ?? 0, 1.5, accuracy: 0.0001)
    }

    func testEffectiveAspectUsesMeasuredOverFallback() {
        // 파서값 없고 디코드 실측값 있으면 그게 fallback 보다 우선 → 보정 완료.
        let a = NetworkImage.effectiveAspect(aspectRatio: nil, measuredAspect: 0.8, fallbackAspect: 1.0)
        XCTAssertEqual(a ?? 0, 0.8, accuracy: 0.0001)
    }

    func testEffectiveAspectFallsBackWhenNoneKnown() {
        // 파서값·실측값 둘 다 없을 때만 fallback (크기 안 주는 보드 throttle).
        let a = NetworkImage.effectiveAspect(aspectRatio: nil, measuredAspect: nil, fallbackAspect: 1.0)
        XCTAssertEqual(a ?? 0, 1.0, accuracy: 0.0001)
    }

    func testEffectiveAspectNilWhenAllNil() {
        // fallback 도 nil(아이콘/스티커 등 비-본문 호출부) → 종전대로 no-op.
        XCTAssertNil(NetworkImage.effectiveAspect(aspectRatio: nil, measuredAspect: nil, fallbackAspect: nil))
    }
}
