import XCTest
import SwiftSoup
@testable import nunting

/// B1: the plain-text fast path in `renderCommentText(fromHTML:)` must produce
/// byte-identical output to the SwiftSoup DOM path for every markup-less input.
/// The whole point is to skip the per-comment `parseBodyFragment` (Document +
/// Element/TextNode/Attribute churn) WITHOUT changing a single rendered
/// character — so this pins the fast path against the original SwiftSoup
/// implementation as an oracle.
final class CommentPlainFastPathTests: XCTestCase {

    /// Minimal `BoardParser` host — `renderCommentText` is a protocol-extension
    /// method and (for plain text) site-independent, so `.ppomppu` is arbitrary.
    private struct StubParser: BoardParser {
        let site: Site = .ppomppu
        func parseList(html: String, board: Board) throws -> [Post] { [] }
        func parseDetail(html: String, post: Post) throws -> PostDetail {
            PostDetail(post: post, blocks: [], fullDateText: nil, viewCount: nil, source: nil, comments: [])
        }
    }

    private let plainSamples: [String] = [
        "안녕하세요 반갑습니다",
        "여러   칸   띄어쓰기",
        "탭\t과\t탭",
        "줄1\n줄2\n\n줄3",
        "  앞뒤 공백  ",
        "\n\n선두 개행\n\n",
        "엔티티 &amp; &lt; &gt; &quot; 처리",
        "숫자엔티티 &#48;&#49;&#50;",
        "앰퍼샌드 단독 a & b",
        "nbsp\u{00A0}하나",
        "nbsp\u{00A0}\u{00A0}둘",
        "&nbsp;선두nbsp 본문",
        "이모지 😀🎉 와 한자 漢字 그리고 ① 특수기호",
        "mixed &amp;\u{00A0} 공백\n탭\t끝   ",
        "캐리지\r리턴\r\n윈도우개행",
        "",
        "   ",
        "\u{00A0}",
        "단일",
    ]

    func testFastPathMatchesSwiftSoupForPlainText() {
        let p = StubParser()
        for s in plainSamples {
            // Guard: every sample is markup-less, so the dispatcher takes the
            // fast path. (If a sample ever contains '<' this assert flags it.)
            XCTAssertFalse(s.contains("<"), "sample must be markup-less: \(s.debugDescription)")
            let fast = p.renderCommentText(fromHTML: s)
            let oracle = p.renderCommentTextViaSwiftSoup(fromHTML: s)
            XCTAssertEqual(
                fast, oracle,
                "plain fast path diverged from SwiftSoup\n  input:  \(s.debugDescription)\n  fast:   \(fast.debugDescription)\n  oracle: \(oracle.debugDescription)")
        }
    }

    /// Markup inputs must still route through SwiftSoup (regression guard so a
    /// future tweak to the `contains("<")` gate can't silently drop the DOM
    /// path for real markup).
    func testMarkupStillUsesSwiftSoupPath() {
        let p = StubParser()
        let withMarkup = "줄1<br>줄2 <a href=\"https://x.com\">링크</a> 끝"
        XCTAssertEqual(
            p.renderCommentText(fromHTML: withMarkup),
            p.renderCommentTextViaSwiftSoup(fromHTML: withMarkup))
    }
}
