import XCTest
@testable import nunting

/// 회귀 가드: 본문이 빈 댓글이라도 **작성자 닉네임이 있으면** 목록에서 통째로
/// 사라지지 않고 작성자만 달린 빈 댓글로 노출돼야 한다. 예전엔 일부 파서
/// (Clien/Coolenjoy/Inven/Ppomppu)가 `content.isEmpty` 만으로 드롭해, 본문이
/// 비거나 파서가 본문 추출에 실패한 댓글이 아예 안 보였다. "작성자/본문/미디어가
/// 전부 빈" 진짜 빈 행만 드롭하도록 통일한다.
final class CommentAuthorOnlyTests: XCTestCase {

    func testClienKeepsAuthorOnlyComment() throws {
        let html = """
        <html><body>
        <div class="post_article">본문</div>
        <div class="comment_row" data-role="comment-row" data-comment-sn="1" data-author-id="u1">
          <span class="nickname">홍길동</span>
          <div class="comment_view"></div>
        </div>
        </body></html>
        """
        let detail = try ClienParser().parseDetail(html: html, post: .fixture(site: .clien))
        XCTAssertEqual(detail.comments.count, 1)
        XCTAssertEqual(detail.comments.first?.author, "홍길동")
        XCTAssertTrue(detail.comments.first?.content.isEmpty == true)
    }

    func testCoolenjoyKeepsAuthorOnlyComment() throws {
        let html = """
        <html><body><article id="c_1">
          <a class="sv_member" title="철수 자기소개">철수</a>
          <textarea id="save_comment_1"></textarea>
        </article></body></html>
        """
        let comments = try CoolenjoyParser().parseComments(html: html)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.author, "철수")
        XCTAssertTrue(comments.first?.content.isEmpty == true)
    }

    func testPpomppuKeepsAuthorOnlyComment() throws {
        let html = """
        <html><body><div class="cmAr"><div class="sect-cmt" data-depth="0">
          <h6 class="com_name"><span class="com_name_writer">영희</span></h6>
          <div id="ctx_5"></div>
        </div></div></body></html>
        """
        let comments = try PpomppuParser().parseComments(html: html)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.author, "영희")
        XCTAssertTrue(comments.first?.content.isEmpty == true)
    }

    func testInvenKeepsAuthorOnlyComment() throws {
        let json = """
        {"commentlist":[{"__attr__":{"titlenum":0},"list":[
          {"__attr__":{"cmtidx":1,"cmtpidx":1},"o_date":"방금","o_name":"민수","o_comment":"","o_recommend":0}
        ]}]}
        """
        let comments = try InvenParser().comments(fromResponseData: Data(json.utf8))
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.author, "민수")
        XCTAssertTrue(comments.first?.content.isEmpty == true)
    }
}
