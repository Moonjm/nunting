import XCTest
@testable import NuntingCore

final class PpomppuParserSmokeTests: XCTestCase {
    private static let board = Board(
        id: "ppomppu",
        site: .ppomppu,
        name: "뽐뿌게시판",
        path: "/zboard/zboard.php?id=ppomppu"
    )

    /// Minimal Ppomppu list HTML — one row with title, link, comment count.
    /// Pinning the smallest legal DOM against the parser keeps `parseList`
    /// honest across SwiftSoup or selector changes.
    func testParseListExtractsSingleRow() throws {
        let html = """
        <html><body>
            <ul class="bbsList_new">
                <li class="">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=999999"><strong>테스트 글 제목</strong></a>
                    <span class="rp">3</span>
                    <time>10:30:00</time>
                </li>
            </ul>
        </body></html>
        """
        let posts = try PpomppuParser().parseList(html: html, board: Self.board)
        XCTAssertEqual(posts.count, 1, "minimal fixture should yield exactly one Post")
        XCTAssertEqual(posts.first?.title, "테스트 글 제목")
        XCTAssertEqual(posts.first?.commentCount, 3)
    }

    /// Pinned-by-popularity rows (`hotpop_bg_color`) break chronological order and
    /// the parser intentionally drops them. Without this assertion the row-skip
    /// branch is invisible regression — a server that re-runs the parser would
    /// see duplicate "hot" entries leaking into the feed.
    ///
    /// fixture는 `<strong>` 폴백 selector를 쓴다(원본 ppomppu의 mis-nested
    /// `<li class="title">`은 SwiftSoup HTML5 normalizer가 sibling으로 hoist시켜
    /// row 카운트가 어긋남). 파서 입장에서 `<strong>` 경로도 정식 fallback이라
    /// hotpop 분기 검증 목적상 충분.
    func testParseListSkipsHotpopPinnedRow() throws {
        let html = """
        <html><body>
            <ul class="bbsList_new">
                <li class="hotpop_bg_color">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=111111"><strong>핫팝 글 (제외 대상)</strong></a>
                    <span class="rp">99</span>
                    <time>09:00:00</time>
                </li>
                <li class="">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=222222"><strong>정상 글</strong></a>
                    <span class="rp">1</span>
                    <time>10:00:00</time>
                </li>
            </ul>
        </body></html>
        """
        let posts = try PpomppuParser().parseList(html: html, board: Self.board)
        XCTAssertEqual(posts.count, 1, "hotpop_bg_color 행은 chronological order를 깨므로 dropped")
        XCTAssertEqual(posts.first?.title, "정상 글")
    }

    /// Sponsored / cross-board rows (e.g. `id=sponsor` at the top of freeboard) carry
    /// a different `id=` query param than the board itself. The parser drops them
    /// to avoid surfacing posts that belong to a different board in the feed.
    func testParseListSkipsCrossBoardSponsorRow() throws {
        let html = """
        <html><body>
            <ul class="bbsList_new">
                <li class="">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=sponsor&no=333333"><strong>스폰서 글</strong></a>
                    <span class="rp">0</span>
                    <time>09:30:00</time>
                </li>
                <li class="">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=444444"><strong>우리 보드 글</strong></a>
                    <span class="rp">2</span>
                    <time>10:30:00</time>
                </li>
            </ul>
        </body></html>
        """
        let posts = try PpomppuParser().parseList(html: html, board: Self.board)
        XCTAssertEqual(posts.count, 1, "id=sponsor 행은 board id 불일치로 dropped")
        XCTAssertEqual(posts.first?.title, "우리 보드 글")
    }

    /// `span.names` 안의 `[카테고리]작성자` 패턴이 `levelText`(카테고리)와 `author`로
    /// 분리되는지 확인. server 측이 같은 파서를 import할 때 카테고리 색인이 빠지면
    /// 키워드 매칭 정확도가 떨어지므로 regression net이 필요.
    ///
    /// `li.names`를 쓰면 SwiftSoup HTML5 normalizer가 outer `<li>`와 분리해 row 카운트가
    /// 어긋나므로 `<span class="names">`로 고정.
    func testParseListSplitsCategoryAndAuthor() throws {
        let html = """
        <html><body>
            <ul class="bbsList_new">
                <li class="">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=555555"><strong>카테고리 분리 테스트</strong></a>
                    <span class="names">[음식]뽐뿌러</span>
                    <span class="rp">5</span>
                    <time>11:00:00</time>
                </li>
            </ul>
        </body></html>
        """
        let posts = try PpomppuParser().parseList(html: html, board: Self.board)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.levelText, "음식")
        XCTAssertEqual(posts.first?.author, "뽐뿌러")
    }

    /// Multi-row 입력에서 각 Post가 고유한 id를 갖는지 + URL에서 `no=`를 정확히 추출하는지.
    /// 만약 누군가 id 빌더를 `\(board.id)-\(hash)`로 바꿔서 충돌이 일어나면 SwiftUI
    /// ForEach 안정성이 깨지므로 pin해둔다.
    func testParseListAssignsDistinctIDsAcrossRows() throws {
        let html = """
        <html><body>
            <ul class="bbsList_new">
                <li class="">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=100"><strong>첫번째</strong></a>
                    <span class="rp">0</span>
                    <time>10:00:00</time>
                </li>
                <li class="">
                    <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=200"><strong>두번째</strong></a>
                    <span class="rp">0</span>
                    <time>10:01:00</time>
                </li>
            </ul>
        </body></html>
        """
        let posts = try PpomppuParser().parseList(html: html, board: Self.board)
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(Set(posts.map(\.id)).count, 2, "id 충돌 — ForEach 안정성 깨짐")
        XCTAssertEqual(posts.map(\.id), ["ppomppu-100", "ppomppu-200"])
    }
}
