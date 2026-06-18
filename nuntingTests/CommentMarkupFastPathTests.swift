import XCTest
import SwiftSoup
@testable import nunting

/// B2: the DOM-free markup scanner (`renderCommentTextLite`) must produce
/// byte-identical output to the SwiftSoup DOM path for the simple-markup
/// comments it claims (block line-breaks / inline emphasis / `<img>`), and
/// must return `nil` (→ SwiftSoup fallback) for anything it can't guarantee
/// — anchors, tables, unknown tags, malformed `<`. Pins both halves of the
/// contract against the unchanged `renderCommentTextViaSwiftSoup` oracle.
final class CommentMarkupFastPathTests: XCTestCase {

    private struct StubParser: BoardParser {
        let site: Site = .ppomppu
        func parseList(html: String, board: Board) throws -> [Post] { [] }
        func parseDetail(html: String, post: Post) throws -> PostDetail {
            PostDetail(post: post, blocks: [], fullDateText: nil, viewCount: nil, source: nil, comments: [])
        }
    }

    /// Markup the scanner SHOULD handle (no anchors / tables / unknown tags).
    private let simpleMarkup: [String] = [
        "줄1<br>줄2",
        "<br/>self-closing 줄바꿈",
        "br연속<br><br>끝",
        "<div>가</div><div>나</div>",
        "앞<p>문단</p>뒤",
        "리스트<li>항목1</li><li>항목2</li>",
        "<blockquote>인용</blockquote>본문",
        "강조<b>볼드</b>보통<i>이탤릭</i>끝",
        "<span>스팬</span>바로텍스트",
        "<strong>강</strong><em>약</em><span>스팬</span><b>볼드</b>",
        "중첩<div>밖<b>볼드<span>안</span></b>끝</div>",
        "이미지<img src=\"x.jpg\">옆텍스트",
        "<img src=\"a.gif\">앞뒤<img src=\"b.gif\">이미지",
        "<div>  여러   칸   공백  </div>",
        "<div>a&nbsp;&nbsp;b 엔티티nbsp</div>",
        "<div>&lt;tag&gt; &amp; &quot;따옴표&quot; 끝</div>",
        "<DIV>대문자<BR>태그</DIV>",
        "<div class='x' id=\"y\">속성있는 div</div>",
        "<font color=red>폰트색</font> 일반",
        "앞<div></div>뒤 빈div",
        "줄바꿈만<br>",
        "<p>선두문단</p>",
        "이모지<br>😀🎉<b>볼드</b>",
        "<span>전각\u{3000}공백</span>지킴",
    ]

    /// Markup the scanner must NOT touch → `nil`, routed to SwiftSoup.
    private let fallbackMarkup: [String] = [
        "링크<a href=\"https://x.com\">텍스트</a> 끝",
        "<a href=\"/rel\">상대링크</a>",
        "<table><tr><td>셀1</td><td>셀2</td></tr></table>",
        "<ul><li>항목</li></ul>",
        "<ol><li>번호</li></ol>",
        "코드<code>x = 1</code>",
        "<pre>형식 보존</pre>",
        "<h3>헤더</h3>본문",
        "<iframe src=\"x\"></iframe>",
        "<video src=\"v.mp4\"></video>",
        "비정형 < 부등호 텍스트",
        "주석<!-- 숨김 -->텍스트",
        // SwiftSoup 이 block 으로 취급해 .text() 가 공백을 넣는 inline 류 → 안전하게 fallback.
        "취소<s>선</s>긋기",
        "밑줄<u>강조</u>표시",
        "위<sup>2</sup>첨자",
        "아래<sub>1</sub>첨자",
    ]

    func testLiteMatchesSwiftSoupForSimpleMarkup() {
        let p = StubParser()
        for s in simpleMarkup {
            // The scanner must actually claim it (else we'd be testing fallback).
            XCTAssertNotNil(p.renderCommentTextLite(fromHTML: s),
                            "scanner should handle simple markup: \(s.debugDescription)")
            let viaDispatcher = p.renderCommentText(fromHTML: s)
            let oracle = p.renderCommentTextViaSwiftSoup(fromHTML: s)
            XCTAssertEqual(
                viaDispatcher, oracle,
                "lite diverged from SwiftSoup\n  input:  \(s.debugDescription)\n  lite:   \(viaDispatcher.debugDescription)\n  oracle: \(oracle.debugDescription)")
        }
    }

    func testComplexMarkupFallsBackAndStillMatches() {
        let p = StubParser()
        for s in fallbackMarkup {
            XCTAssertNil(p.renderCommentTextLite(fromHTML: s),
                         "scanner should defer to SwiftSoup: \(s.debugDescription)")
            // Dispatcher falls back → still identical to the oracle by construction.
            XCTAssertEqual(p.renderCommentText(fromHTML: s),
                           p.renderCommentTextViaSwiftSoup(fromHTML: s),
                           "fallback path mismatch: \(s.debugDescription)")
        }
    }
}
