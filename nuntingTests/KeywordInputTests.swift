import XCTest
@testable import nunting

final class KeywordInputTests: XCTestCase {

    // MARK: - parse

    func testParseSeparatesIncludeAndExclude() {
        let r = KeywordInput.parse("갤럭시, s24, -중고, -판매")
        XCTAssertEqual(r.include, "갤럭시,s24")
        XCTAssertEqual(r.exclude, "중고,판매")
    }

    func testParseIncludeOnly() {
        let r = KeywordInput.parse("삼다수, 500ml")
        XCTAssertEqual(r.include, "삼다수,500ml")
        XCTAssertEqual(r.exclude, "")
    }

    func testParseExcludeOnlyHasEmptyInclude() {
        let r = KeywordInput.parse("-중고, -판매")
        XCTAssertEqual(r.include, "")
        XCTAssertEqual(r.exclude, "중고,판매")
    }

    func testParseTrimsSpacesAroundDashAndTokens() {
        let r = KeywordInput.parse("  갤럭시 ,  -  중고  ")
        XCTAssertEqual(r.include, "갤럭시")
        XCTAssertEqual(r.exclude, "중고")
    }

    func testParseDropsEmptyAndBareDashTokens() {
        let r = KeywordInput.parse("갤럭시, , -, -중고")
        XCTAssertEqual(r.include, "갤럭시")
        XCTAssertEqual(r.exclude, "중고")
    }

    func testParseKeepsMidTokenHyphenLiteral() {
        // 중간 하이픈은 리터럴 — 접두 - 1개만 제외 플래그.
        let r = KeywordInput.parse("갤럭시-탭, -중고-나라")
        XCTAssertEqual(r.include, "갤럭시-탭")
        XCTAssertEqual(r.exclude, "중고-나라")
    }

    // MARK: - compose (round-trip for row editing)

    func testComposeRebuildsEditableString() {
        XCTAssertEqual(
            KeywordInput.compose(keyword: "갤럭시,s24", exclude: "중고,판매"),
            "갤럭시, s24, -중고, -판매")
    }

    func testComposeNoExclude() {
        XCTAssertEqual(KeywordInput.compose(keyword: "삼다수,500ml", exclude: ""),
                       "삼다수, 500ml")
    }

    func testParseComposeRoundTrip() {
        // compose 결과를 다시 parse 하면 (정규화 무시하고) 같은 토큰 집합.
        let composed = KeywordInput.compose(keyword: "갤럭시,s24", exclude: "중고,판매")
        let reparsed = KeywordInput.parse(composed)
        XCTAssertEqual(reparsed.include, "갤럭시,s24")
        XCTAssertEqual(reparsed.exclude, "중고,판매")
    }
}
