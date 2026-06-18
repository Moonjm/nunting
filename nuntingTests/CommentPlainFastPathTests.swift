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
        // Non-ASCII spaces SwiftSoup's byte-level .text() must NOT collapse
        // (only ASCII ws + U+00A0 collapse) — these are plausible Korean input.
        "전각\u{3000}공백",            // U+3000 ideographic space
        "제로폭\u{200B}공백",          // U+200B zero-width space
        "수직탭\u{000B}끝",            // U+000B vertical tab (not in collapse set)
        "유니코드\u{2009}씬스페이스",   // U+2009 thin space
        // Numeric / malformed / out-of-range character references — must decode
        // identically to the tokeniser's consumeCharacterReference.
        "제어 &#1; 문자",
        "윈1252 &#128; 유로",
        "범위초과 &#x110000; 끝",
        "널 &#0; 참조",
        "세미없음 &amp 본문",
        // Sentinel injection: literal marker bytes in input — both paths must
        // mistransform identically (contract holds even if output is odd).
        "센티넬\u{0001}SP\u{0001}주입",
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
        let rendered = p.renderCommentText(fromHTML: withMarkup)
        // Routed to SwiftSoup → identical to the oracle...
        XCTAssertEqual(rendered, p.renderCommentTextViaSwiftSoup(fromHTML: withMarkup))
        // ...and the DOM path actually ran (the plain path can't emit a `<br>`
        // newline or an anchor→markdown link), documenting the gate's intent.
        XCTAssertTrue(rendered.contains("\n"), "<br> should become a newline via the DOM path")
        XCTAssertTrue(rendered.contains("[링크](") && rendered.contains("x.com"),
                      "anchor should become a markdown link via the DOM path")
    }
}
