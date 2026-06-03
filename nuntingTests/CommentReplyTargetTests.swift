import XCTest
@testable import nunting

/// 답글 대상 닉네임을 구조화 필드(replyTarget)로 surface 하는지 — Etoland(중첩
/// 트리 → 부모 author), Ddanzi(.re_com_nickname "@대상" 버블). 뷰가 파란 @대상 렌더.
final class CommentReplyTargetTests: XCTestCase {

    // MARK: Etoland — childrenComments 의 부모 author 가 답글 대상

    func testEtolandReplyTargetIsParentAuthor() async throws {
        let parser = EtolandParser()
        let post = Post.fixture(
            id: "x",
            site: .etoland,
            boardID: "aagag",
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-9022769")!
        )
        let bailoutHTML = "<html><template data-dgst=\"BAILOUT_TO_CLIENT_SIDE_RENDERING\"></template></html>"
        // 부모(을) + 자식 답글(병→을).
        let apiBody = """
        {"status":"ETOCD200000","data":{"comments":[
          {"commentId":200,"parentId":null,"writeDateTimestamp":1,"recommendCount":0,"content":"부모","isAnonymous":false,"member":{"nickname":"을","image":null},"file":null,"childrenComments":[
            {"commentId":201,"parentId":200,"writeDateTimestamp":2,"recommendCount":0,"content":"답글","isAnonymous":false,"member":{"nickname":"병","image":null},"file":null,"childrenComments":[]}
          ]}
        ]}}
        """
        let comments = try await parser.fetchAllComments(for: post, detailHTML: bailoutHTML) { _ in apiBody }

        XCTAssertEqual(comments.count, 2)
        XCTAssertFalse(comments[0].isReply)
        XCTAssertNil(comments[0].replyTarget)
        XCTAssertEqual(comments[1].author, "병")
        XCTAssertTrue(comments[1].isReply)
        XCTAssertEqual(comments[1].replyTarget, "을", "자식 답글의 대상은 부모 닉네임")
    }

    // MARK: Ddanzi — .re_com_nickname("@대상") → replyTarget, content 에선 제거

    func testDdanziReplyTargetFromNicknameSpan() throws {
        let html = """
        <ul>
        <li id="comment_1"><div class="fbItem"><div class="fbMeta">\
        <h4 class="author"><a>원댓글러</a></h4><p class="time">14:00</p></div>\
        <div class="fdComment"><div class="xe_content">원댓글</div></div></div></li>
        <li id="comment_2" class="re_comment"><div class="fbItem"><div class="fbMeta">\
        <h4 class="author"><a>장쟝</a></h4><p class="time">15:37</p></div>\
        <div class="fdComment"><div class="xe_content">\
        <span class="re_com_nickname">@마리다마리아</span>그러게요.</div></div></div></li>
        </ul>
        """
        let data = try JSONSerialization.data(withJSONObject: ["error": 0, "commentHtml": html])
        let comments = DdanziParser().decodeComments(data: data)

        XCTAssertEqual(comments.count, 2)
        // 원댓글: 대상 없음.
        XCTAssertFalse(comments[0].isReply)
        XCTAssertNil(comments[0].replyTarget)
        XCTAssertEqual(comments[0].content, "원댓글")
        // 답글: 대상은 replyTarget("@" 제거), content 엔 닉네임 안 남음.
        XCTAssertTrue(comments[1].isReply)
        XCTAssertEqual(comments[1].replyTarget, "마리다마리아")
        XCTAssertEqual(comments[1].content, "그러게요.")
        XCTAssertFalse(comments[1].content.contains("마리다마리아"))
    }
}
