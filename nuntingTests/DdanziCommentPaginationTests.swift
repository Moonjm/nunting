import XCTest
@testable import nunting

/// 딴지 댓글 페이지 수 감지. cpage=0 만 받으면 XE 가 "마지막 페이지"만 줘서
/// 앞 페이지 댓글이 빠지던 버그(#딴지 댓글 페이지네이션) 회귀 방지.
final class DdanziCommentPaginationTests: XCTestCase {
    private func data(_ html: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["error": 0, "commentHtml": html])
    }

    func testPageCountFromPageNoInput() throws {
        // XE 가 fragment 에 심는 _page_no = 총 페이지 수(현재 페이지와 무관).
        let html = """
        <ul><li id="comment_1"><div class="fbItem"></div></li></ul>
        <div class="board_page"><div class="pagination">
        <a class="active number">1</a>\
        <a class="number" href="javascript:comment_page('2');">2</a>
        </div></div>
        <input type="hidden" id="_page_no" value="2" />
        """
        XCTAssertEqual(DdanziParser().decodeCommentPageCount(data: try data(html)), 2)
    }

    func testPageNoPreferredOverWindowedNumberAnchors() throws {
        // 윈도잉으로 .number 가 1..3 만 보여도 _page_no=10 이면 10 을 신뢰.
        let html = """
        <div class="pagination">
        <a class="active number">1</a>\
        <a class="number" href="#">2</a><a class="number" href="#">3</a>
        </div>
        <input type="hidden" id="_page_no" value="10" />
        """
        XCTAssertEqual(DdanziParser().decodeCommentPageCount(data: try data(html)), 10)
    }

    func testFallsBackToMaxNumberAnchorWhenNoPageNo() throws {
        let html = """
        <div class="pagination">
        <a class="number" href="#">1</a>\
        <a class="active number">2</a>\
        <a class="number" href="#">3</a>
        </div>
        """
        XCTAssertEqual(DdanziParser().decodeCommentPageCount(data: try data(html)), 3)
    }

    func testSinglePageReturnsOne() throws {
        let html = "<ul><li id=\"comment_1\"><div class=\"fbItem\"></div></li></ul>"
        XCTAssertEqual(DdanziParser().decodeCommentPageCount(data: try data(html)), 1)
    }

    func testGarbageOrEmptyReturnsOne() throws {
        XCTAssertEqual(DdanziParser().decodeCommentPageCount(data: Data("not json".utf8)), 1)
        XCTAssertEqual(DdanziParser().decodeCommentPageCount(data: try data("")), 1)
    }
}
