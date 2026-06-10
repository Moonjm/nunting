import XCTest
@testable import nunting

/// 댓글 `<br>` 줄바꿈 보존 회귀 방지 — Bobae/Clien/Humor.
///
/// SwiftSoup `.text()` 는 whitespace 를 정규화하므로 `<br>` 앞에 끼워 넣은
/// `\n` TextNode 도 한 칸 공백으로 접힌다 (DdanziParser 주석에 문서화된
/// 동일 함정). 이 때문에 `renderCommentText` 파이프라인(blockMarker
/// sentinel)을 타지 않던 세 파서의 댓글 줄바꿈이 전부 사라졌다.
final class CommentNewlineTests: XCTestCase {

    // MARK: - Bobae

    func testBobaeCommentPreservesBRLineBreaks() async throws {
        let parser = BobaeParser()
        // 페이저 없는 단일 페이지 detail — 추가 fetch 없이 inline 만 파싱.
        let detail = """
        <html><body><div class="reple_body"><ul class="list">
        <li>
          <div class="con_area">
            <div class="reply">첫째 줄<br>둘째 줄</div>
            <div class="util"><span class="data4">작성자</span><span>12:34</span></div>
          </div>
          <input id="repl_length_77">
        </li>
        </ul></div></body></html>
        """
        let post = Post.fixture(
            id: "strange-1", site: .bobae, boardID: "strange",
            url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/strange/1")!)
        let comments = try await parser.fetchAllComments(for: post, detailHTML: detail) { _ in
            XCTFail("단일 페이지 — 추가 fetch 없어야 함")
            return ""
        }
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments[0].content, "첫째 줄\n둘째 줄")
    }

    // MARK: - Clien

    func testClienCommentPreservesBRLineBreaks() throws {
        let parser = ClienParser()
        let html = """
        <html><body>
        <div class="post_article"><p>본문</p></div>
        <div class="comment_row" data-role="comment-row" data-comment-sn="42" data-author-id="u1">
          <span class="nickname">닉네임</span>
          <span class="timestamp">2026-06-10 12:01</span>
          <div class="comment_view">첫째 줄<br>둘째 줄</div>
        </div>
        </body></html>
        """
        let post = Post.fixture(
            site: .clien,
            url: URL(string: "https://m.clien.net/service/board/park/1")!)
        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(detail.comments.count, 1)
        XCTAssertEqual(detail.comments[0].content, "첫째 줄\n둘째 줄")
    }

    // MARK: - Humor

    func testHumorCommentPreservesBRLineBreaks() throws {
        let parser = HumorParser()
        let html = """
        <html><body>
        <div id="read_subject_div"><h2><a>제목</a></h2></div>
        <div id="comment"><ul>
          <li id="comment_li_9">
            <div class="nick"><span class="hu_nick_txt">닉</span></div>
            <span class="etc">2026-06-10 12:00</span>
            <div class="comment_body"><div class="comment_text">첫째 줄<br>둘째 줄</div></div>
          </li>
        </ul></div>
        </body></html>
        """
        let post = Post.fixture(
            site: .humor,
            url: URL(string: "https://m.humoruniv.com/board/read.html?table=pds&number=1")!)
        let detail = try parser.parseDetail(html: html, post: post)
        XCTAssertEqual(detail.comments.count, 1)
        XCTAssertEqual(detail.comments[0].content, "첫째 줄\n둘째 줄")
    }
}
