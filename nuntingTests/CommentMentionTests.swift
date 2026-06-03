import XCTest
import SwiftSoup
@testable import nunting

/// 뽐뿌 대댓글 멘션 "@킬길123 아.." 에서 강조가 "아" 까지 먹던 버그 회귀 가드.
/// 근본 원인: `<b>@닉</b>&nbsp;본문` 의 `&nbsp;`(U+00A0) 가 flatten 에서 유실돼
/// "@닉본문" 으로 붙고, 멘션 루프가 본문 첫 글자까지 강조했다.
final class CommentMentionTests: XCTestCase {

    // 실제 m.ppomppu 댓글 HTML 조각 (id=phone no=3918334, ctx_38591094).
    private let realCommentHTML = """
    <div id="ctx_38591094" class="comment_memo my-gallery mid-text-area">
    <table class="content"><tr><td>
    <p>
    <b class="cheditor_tonick">@킬길123</b>&nbsp;아.. 그 뜻이군요 ㅋ 제한 해제 후 셀프 개통이 가능할지 모르겠네요.. 막아둔 것 같기도 하고..
    </p>                </td></tr>
    </table>
    </div>
    """

    func testMentionNotMergedWithFollowingWord() throws {
        let doc = try SwiftSoup.parse(realCommentHTML)
        let ctx = try XCTUnwrap(doc.select("[id^=ctx_]").first())
        let rendered = PpomppuParser().renderCommentText(from: ctx)

        // nbsp 가 공백으로 보존돼 닉네임과 본문이 분리돼야 한다.
        XCTAssertTrue(rendered.hasPrefix("@킬길123 아.."),
                      "닉네임/본문이 붙었습니다: \(rendered.debugDescription)")
        XCTAssertFalse(rendered.contains("123아"), "nbsp 유실로 단어가 붙음")

        // 멘션 강조 루프(PostDetailComments.computeStyledContent 복제)가 닉네임만 잡아야.
        XCTAssertEqual(Self.firstMentionSubstring(in: rendered), "@킬길123")
    }

    /// PostDetailComments.computeStyledContent 의 멘션 탐지 루프 복제(회귀 가드용).
    private static func firstMentionSubstring(in text: String) -> String {
        let plain = text
        var i = plain.startIndex
        while i < plain.endIndex {
            guard plain[i] == "@" else { i = plain.index(after: i); continue }
            var end = plain.index(after: i)
            while end < plain.endIndex,
                  plain[end].isLetter || plain[end].isNumber || plain[end] == "_" {
                end = plain.index(after: end)
            }
            if end > plain.index(after: i) {
                return String(plain[i..<end])
            }
            i = end
        }
        return ""
    }
}
