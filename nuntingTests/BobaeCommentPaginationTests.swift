import XCTest
@testable import nunting

/// 보배드림 모바일 detail 은 댓글 **마지막 페이지**(50개/페이지)를 inline 으로
/// 렌더하고 나머지 페이지는 `comment_call` AJAX 로 가져온다. 파서가 inline 만
/// 읽어 61개 글에서 11개만 보이던 버그 회귀 방지. (뽐뿌와 동일 부류)
final class BobaeCommentPaginationTests: XCTestCase {
    /// 병렬 fetch 가 요청한 page 파라미터를 thread-safe 하게 기록.
    private actor PageRecorder {
        private(set) var pages: [String] = []
        func add(_ p: String) { pages.append(p) }
    }

    private func post() -> Post {
        Post.fixture(
            id: "strange-6925135", site: .bobae, boardID: "strange",
            url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/strange/6925135")!)
    }

    /// `comment_call(sel_tb, mapCD, mapNO, ocode, ono, page, order)` 의 page 인자.
    private func pageParam(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "page" })?.value ?? "?"
    }

    private func commentLI(_ content: String, author: String, id: Int) -> String {
        """
        <li>
          <div class="con_area">
            <div class="reply">\(content)</div>
            <div class="util"><span class="data4">\(author)</span><span>12:34</span></div>
          </div>
          <input id="repl_length_\(id)" />
        </li>
        """
    }

    /// 댓글 페이저: `.page span.num` — 현재 페이지는 `a.on`, 나머지는 comment_call.
    private func pager(current: Int, total: Int) -> String {
        var anchors = ""
        for p in 1...total {
            if p == current {
                anchors += "<a class=\"on\" href=\"#\">\(p)</a>"
            } else {
                anchors += "<a href=\"javascript:comment_call('uni_cmt_2606', 'strange', '6925135', 'strange', '6925135','\(p)','');\">\(p)</a>"
            }
        }
        return "<div class=\"page\"><span class=\"num\">\(anchors)</span></div>"
    }

    /// detail 페이지: 댓글이 `.reple_body > ul.list > li` 에 inline.
    private func detailHTML(current: Int, total: Int, comments: [(String, String, Int)]) -> String {
        let lis = comments.map { commentLI($0.0, author: $0.1, id: $0.2) }.joined()
        return """
        <html><body>
        <div class="reple_body"><ul class="list">\(lis)</ul>\(pager(current: current, total: total))</div>
        </body></html>
        """
    }

    /// AJAX `comment_call` 응답: `.reple_body` 래퍼 없이 `ul.list > li` 만.
    private func fragment(current: Int, total: Int, comments: [(String, String, Int)]) -> String {
        let lis = comments.map { commentLI($0.0, author: $0.1, id: $0.2) }.joined()
        return "<ul class=\"list\">\(lis)</ul>\(pager(current: current, total: total))"
    }

    func testFetchesMissingPagesAndMergesInPageOrder() async throws {
        let parser = BobaeParser()
        // detail = 마지막 페이지(2/2) inline.
        let detail = detailHTML(current: 2, total: 2, comments: [
            ("p2a", "글쓴이2a", 21), ("p2b", "글쓴이2b", 22),
        ])

        let recorder = PageRecorder()
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: detail) { url in
            await recorder.add(self.pageParam(of: url))
            XCTAssertTrue(url.absoluteString.contains("/board/comment_call/"), "댓글 AJAX 엔드포인트여야 함")
            return self.fragment(current: 1, total: 2, comments: [
                ("p1a", "글쓴이1a", 11), ("p1b", "글쓴이1b", 12),
            ])
        }

        // page1(빠진 것) → page2(inline) 순서로, 누락/중복 없이.
        XCTAssertEqual(comments.map(\.content), ["p1a", "p1b", "p2a", "p2b"])
        // detail = page2 재사용 → page1 만 fetch.
        let requested = await recorder.pages
        XCTAssertEqual(requested, ["1"], "inline 페이지(2)는 재사용, 빠진 1만 가져옴")
    }

    func testSinglePageReusesInlineWithoutFetching() async throws {
        let parser = BobaeParser()
        // 페이저 없는 단일 페이지 detail.
        let detail = """
        <html><body><div class="reple_body"><ul class="list">\
        \(commentLI("only", author: "혼자", id: 1))\
        </ul></div></body></html>
        """
        let recorder = PageRecorder()
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: detail) { url in
            await recorder.add(self.pageParam(of: url))
            return ""
        }
        XCTAssertEqual(comments.map(\.content), ["only"])
        let requested = await recorder.pages
        XCTAssertTrue(requested.isEmpty, "단일 페이지는 추가 fetch 없이 inline 재사용")
    }

    /// id 없는(`repl_` 부재) 댓글이 서로 다른 페이지에 있을 때, 페이지별로
    /// 0 부터 다시 시작하는 enumerate idx 만으로 synthetic id 를 만들면 충돌한다
    /// (SwiftUI ForEach 키 클래시). page 를 섞어 고유해야 한다.
    func testIdLessCommentsAcrossPagesGetUniqueIDs() async throws {
        let parser = BobaeParser()
        // page2 inline: repl_ 없는 댓글.
        let detail = """
        <html><body><div class="reple_body"><ul class="list">\
        <li><div class="con_area"><div class="reply">p2only</div>\
        <div class="util"><span class="data4">A</span><span>1:00</span></div></div></li>\
        </ul>\(pager(current: 2, total: 2))</div></body></html>
        """
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: detail) { _ in
            // page1 fragment: 역시 repl_ 없는 댓글.
            """
            <ul class="list"><li><div class="con_area"><div class="reply">p1only</div>\
            <div class="util"><span class="data4">B</span><span>2:00</span></div></div></li></ul>\
            \(self.pager(current: 1, total: 2))
            """
        }
        XCTAssertEqual(comments.map(\.content), ["p1only", "p2only"])
        XCTAssertEqual(Set(comments.map(\.id)).count, 2, "페이지 다른 id 없는 댓글은 서로 다른 id 여야 함")
    }

    /// 현재 페이지 표시(`a.on`)가 없으면 마크업이 바뀐 것 — current 를 1 로
    /// 임의 슬롯하면 inline(실제 마지막 페이지)이 fetch 한 page 1 과 충돌하므로,
    /// 안전하게 inline-only 로 내려가야 한다(수정 전 동작).
    func testPagerWithoutCurrentMarkerFallsBackToInline() async throws {
        let parser = BobaeParser()
        let pagerNoOn = """
        <div class="page"><span class="num">\
        <a href="javascript:comment_call('uni_cmt_2606', 'strange', '6925135', 'strange', '6925135','1','');">1</a>\
        <a href="javascript:comment_call('uni_cmt_2606', 'strange', '6925135', 'strange', '6925135','2','');">2</a>\
        </span></div>
        """
        let detail = """
        <html><body><div class="reple_body"><ul class="list">\
        \(commentLI("inline", author: "A", id: 1))\
        </ul>\(pagerNoOn)</div></body></html>
        """
        let recorder = PageRecorder()
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: detail) { url in
            await recorder.add(self.pageParam(of: url))
            return ""
        }
        XCTAssertEqual(comments.map(\.content), ["inline"])
        let requested = await recorder.pages
        XCTAssertTrue(requested.isEmpty, "a.on 없으면 추가 fetch 없이 inline-only")
    }

    func testPageFetchFailureIsAbsorbedAndInlineSurvives() async throws {
        struct PageError: Error {}
        let parser = BobaeParser()
        let detail = detailHTML(current: 2, total: 2, comments: [("p2a", "글쓴이", 21)])

        // page1 fetch 가 실패해도 inline(page2)은 살아야 한다.
        let comments = try await parser.fetchAllComments(for: post(), detailHTML: detail) { _ in
            throw PageError()
        }
        XCTAssertEqual(comments.map(\.content), ["p2a"])
    }
}
