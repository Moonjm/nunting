import XCTest
@testable import nunting

/// SLR 답글의 대상 닉네임(JSON `tn`)을 웹처럼 `[이름]` 으로 본문 앞에 노출하는지.
/// 회귀: 앱이 tn 을 버려 답글에 누구한테 단 건지 안 보이던 버그.
final class SLRReplyTargetTests: XCTestCase {

    // 실제 m.slrclub.com /bbs/comment_db/load.php JSON 모양(축약).
    private let json = """
    {"c":[
      {"pk":"a1","name":"한국참교육협회","memo":" 원댓글 내용","vt":1,"dt":"14:00","th":null,"tn":null,"del":0},
      {"pk":"a2","name":"손배전문","memo":" 노무현 대통령 조롱하는게 놀이..","vt":0,"dt":"14:19","th":393208806,"tn":"한국참교육협회","del":0}
    ]}
    """

    func testReplyShowsTargetNameInBrackets() throws {
        let data = Data(json.utf8)
        let comments = SLRParser().decodeComments(data: data)

        XCTAssertEqual(comments.count, 2)

        // 원댓글: 대상 없음 → 대괄호 없음.
        XCTAssertEqual(comments[0].author, "한국참교육협회")
        XCTAssertFalse(comments[0].isReply)
        XCTAssertEqual(comments[0].content, "원댓글 내용")

        // 답글: 대상(tn) 이 `[이름]` 으로 본문 앞에.
        XCTAssertTrue(comments[1].isReply)
        XCTAssertEqual(comments[1].content, "[한국참교육협회] 노무현 대통령 조롱하는게 놀이..")
    }
}
