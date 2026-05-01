import XCTest
@testable import nunting

/// Fixture-based regression tests for parser `parseList` selectors.
///
/// Fixtures are intentionally embedded as Swift string literals rather
/// than bundled resources to keep the test target self-contained — no
/// `PBXResourcesBuildPhase` plumbing needed for synced groups, and a
/// failing fixture diff is readable straight from the test source.
///
/// What these protect against: silent regressions when SwiftSoup
/// selector strings drift away from the live site DOM (notice rows
/// leaking into the feed, dedup keys collapsing, source-tag class
/// extraction breaking, etc.). They do *not* replace fetching real
/// HTML — they pin the parser's behavior against the smallest legal
/// DOM that exercises each selector branch.
final class ParserListTests: XCTestCase {

    // MARK: - Clien

    func testClienListSkipsNoticeRowsAndAdSlots() throws {
        let html = """
        <html><body>
        <a class="list_item symph-row" href="/service/board/news/19000001"
           data-board-sn="19000001" data-comment-count="42" data-author-id="someone">
            <span data-role="list-title-text">실제 글 제목</span>
            <div class="list_author"><span class="nickname">정상유저</span></div>
            <div class="list_time"><span>2026-05-01 12:34</span></div>
        </a>
        <a class="list_item notice symph-row" href="/service/board/news/19000002"
           data-board-sn="19000002" data-comment-count="0">
            <span data-role="list-title-text">고정 공지</span>
        </a>
        <a class="list_item symph-row" href="/service/board/news/19000003"
           data-board-sn="19000003" data-comment-count="0">
            <div class="ad">알리정보</div>
            <span data-role="list-title-text">스폰서 글</span>
        </a>
        <a class="list_item symph-row" href="/service/board/news/19000004"
           data-board-sn="19000004" data-comment-count="3">
            <span data-role="list-title-text">두번째 정상글</span>
            <div class="list_author"><span class="nickname">유저B</span></div>
            <div class="list_time"><span>2026-05-01 13:00</span></div>
        </a>
        </body></html>
        """
        let parser = ClienParser()
        let posts = try parser.parseList(html: html, board: .clienNews)
        XCTAssertEqual(posts.count, 2, "공지 + ad 행은 결과에서 제외되어야 함")
        XCTAssertEqual(posts[0].title, "실제 글 제목")
        XCTAssertEqual(posts[0].author, "정상유저")
        XCTAssertEqual(posts[0].dateText, "2026-05-01 12:34")
        XCTAssertEqual(posts[0].commentCount, 42)
        XCTAssertEqual(posts[0].id, "clien-news-19000001")
        XCTAssertEqual(posts[0].url.absoluteString, "https://www.clien.net/service/board/news/19000001")
        XCTAssertEqual(posts[1].title, "두번째 정상글")
        XCTAssertEqual(posts[1].id, "clien-news-19000004")
    }

    func testClienListAuthorFallsBackToDataAttribute() throws {
        // When the markup omits `.list_author span.nickname` the parser
        // should fall back to `data-author-id` rather than emitting a
        // post with an empty author string.
        let html = """
        <html><body>
        <a class="list_item symph-row" href="/service/board/news/19000010"
           data-board-sn="19000010" data-comment-count="0" data-author-id="anonymous_v3">
            <span data-role="list-title-text">닉네임 빠진 글</span>
        </a>
        </body></html>
        """
        let parser = ClienParser()
        let posts = try parser.parseList(html: html, board: .clienNews)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].author, "anonymous_v3")
    }

    // MARK: - Inven

    func testInvenListBasicRowParsesAllFields() throws {
        let html = """
        <html><body>
        <section class="mo-board-list">
        <ul>
        <li class="list">
            <a class="contentLink" href="/board/maple/5974/12345">
                <span class="subject">메이플 인벤 글 제목</span>
            </a>
            <span class="layerNickName">메이플유저<span class="maple"></span></span>
            <span class="time">2분전</span>
            <span class="lv">Lv.42</span>
            <span class="view">조회 1,234</span>
            <span class="reco">추천 5</span>
            <a class="com-btn"><span class="num">7</span></a>
        </li>
        <li class="list">
            <a class="contentLink" href="/board/maple/5974/12346">
                <span class="subject">댓글 0인 글</span>
            </a>
            <span class="layerNickName">다른유저</span>
            <span class="time">10분전</span>
            <a class="com-btn"><span class="num">0</span></a>
        </li>
        </ul>
        </section>
        </body></html>
        """
        let parser = InvenParser()
        let posts = try parser.parseList(html: html, board: .invenMaple)
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].title, "메이플 인벤 글 제목")
        XCTAssertEqual(posts[0].author, "메이플유저")
        XCTAssertEqual(posts[0].dateText, "2분전")
        XCTAssertEqual(posts[0].levelText, "Lv.42")
        XCTAssertEqual(posts[0].viewCount, 1234, "콤마 포함된 조회수도 숫자만 추출")
        XCTAssertEqual(posts[0].recommendCount, 5)
        XCTAssertEqual(posts[0].commentCount, 7)
        XCTAssertTrue(posts[0].hasAuthIcon, "span.maple 인증 아이콘 감지")
        XCTAssertEqual(posts[0].id, "inven-maple-12345")
        XCTAssertEqual(posts[1].commentCount, 0)
        XCTAssertNil(posts[1].viewCount, "view span 없을 땐 nil")
        XCTAssertNil(posts[1].recommendCount)
        XCTAssertFalse(posts[1].hasAuthIcon)
    }

    func testInvenListSkipsRowsWithoutTitleOrLink() throws {
        // Empty / link-less rows must not surface as ghost posts with
        // blank titles — they're commonly section dividers in inven HTML.
        let html = """
        <html><body>
        <section class="mo-board-list">
        <ul>
        <li class="list"><div class="divider"></div></li>
        <li class="list">
            <a class="contentLink" href="/board/maple/5974/99999">
                <span class="subject"></span>
            </a>
            <span class="layerNickName">유저</span>
        </li>
        <li class="list">
            <a class="contentLink" href="/board/maple/5974/77777">
                <span class="subject">유효한 글</span>
            </a>
            <span class="layerNickName">유저</span>
            <a class="com-btn"><span class="num">1</span></a>
        </li>
        </ul>
        </section>
        </body></html>
        """
        let parser = InvenParser()
        let posts = try parser.parseList(html: html, board: .invenMaple)
        XCTAssertEqual(posts.count, 1, "title 없는 빈 row 와 contentLink 없는 row 는 모두 skip")
        XCTAssertEqual(posts[0].title, "유효한 글")
    }

    // MARK: - Aagag

    func testAagagMirrorListExtractsSourceTagAndDeduplicates() throws {
        // Mirror entries carry `bc_<site>` on `span.rank`/`span.lo`; the parser
        // strips the prefix and stores the bare site code in `levelText`.
        // Duplicate `ss=` keys (hot reposts at the bottom of issue pages)
        // must collapse to one Post.
        let html = """
        <html><body>
        <table class="aalist">
        <tr>
            <td>
                <a class="article" href="re?ss=ppomppu_111" ss="ppomppu_111">
                    <span class="rank bc_ppomppu">1</span>
                    <span class="title">뽐뿌 인기글<span class="cmt">5</span></span>
                    <span class="date"><u>2분전</u></span>
                    <span class="hit"><u>1,234</u></span>
                    <span class="nick"><u>뽐뿌유저</u></span>
                </a>
            </td>
        </tr>
        <tr>
            <td>
                <a class="article" href="./re?ss=humor_222" ss="humor_222">
                    <span class="rank bc_humor">2</span>
                    <span class="title">웃대 인기글<span class="cmt">12</span></span>
                    <span class="date"><u>5분전</u></span>
                </a>
            </td>
        </tr>
        <tr>
            <td>
                <a class="article" href="re?ss=ppomppu_111" ss="ppomppu_111">
                    <span class="rank bc_ppomppu">3</span>
                    <span class="title">중복 항목</span>
                </a>
            </td>
        </tr>
        </table>
        </body></html>
        """
        let parser = AagagParser()
        let posts = try parser.parseList(html: html, board: .aagag)
        XCTAssertEqual(posts.count, 2, "ss=ppomppu_111 두 건은 dedup 되어 1건으로 합쳐짐")
        XCTAssertEqual(posts[0].title, "뽐뿌 인기글")
        XCTAssertEqual(posts[0].levelText, "ppomppu", "bc_ 접두사 제거된 site 코드")
        XCTAssertEqual(posts[0].commentCount, 5, "title 안의 span.cmt 댓글 수")
        XCTAssertEqual(posts[0].viewCount, 1234)
        XCTAssertEqual(posts[0].author, "뽐뿌유저")
        XCTAssertEqual(posts[0].id, "aagag-ppomppu_111")
        XCTAssertEqual(posts[0].url.path, "/mirror/re", "rawHref 're?...' 가 /mirror/re 로 prefixed")
        XCTAssertEqual(posts[1].title, "웃대 인기글")
        XCTAssertEqual(posts[1].levelText, "humor")
        XCTAssertEqual(posts[1].url.path, "/mirror/re", "'./re?...' 도 동일하게 정규화")
    }
}
