import XCTest
@testable import NuntingCore

final class PpomppuParserSmokeTests: XCTestCase {
    /// Minimal Ppomppu list HTML — one row with title, link, comment count.
    /// Pinning the smallest legal DOM against the parser keeps `parseList`
    /// honest across SwiftSoup or selector changes.
    func testParseListExtractsSingleRow() throws {
        let html = """
        <html><body>
            <ul class="bbsList_new">
                <li class="">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=999999">
                        <li class="title"><span class="cont">테스트 글 제목</span></li>
                    </a>
                    <span class="rp">3</span>
                    <time>10:30:00</time>
                </li>
            </ul>
        </body></html>
        """
        let board = Board(
            id: "ppomppu",
            site: .ppomppu,
            name: "뽐뿌게시판",
            path: "/zboard/zboard.php?id=ppomppu"
        )
        let posts = try PpomppuParser().parseList(html: html, board: board)
        XCTAssertEqual(posts.count, 1, "minimal fixture should yield exactly one Post")
        XCTAssertEqual(posts.first?.title, "테스트 글 제목")
    }
}
