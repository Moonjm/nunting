import XCTest
import SwiftSoup
@testable import nunting

/// 회귀 가드: 파싱한 SwiftSoup Document/Element 가 스코프를 벗어나면 실제로
/// 해제되는지(=누수 없음) weak 참조로 확인한다. SwiftSoup 2.12~2.13.4 는
/// `.select()` 가 per-Element 캐시의 strong upward 참조(`selectorResultCacheRoot`)
/// 로 DOM 전체를 retain cycle 에 가둬, 글 열기마다 Document 가 영구 잔류 → OOM
/// 이었다(2.13.5/PR#395 의 weak 수정으로 해결). 미래에 SwiftSoup 다운그레이드나
/// 다른 cycle 재도입으로 누수가 돌아오면 이 테스트가 빨갛게 잡는다.
final class SwiftSoupLeakProbeTests: XCTestCase {

    /// parse 만 하고 `.select()` 를 안 하면 누수가 없어야 한다 — 누수의 원인이
    /// selector 결과 캐시(`selectorResultCacheRoot` strong upward 참조)임을 격리.
    func testParseOnlyWithoutSelectDeallocates() throws {
        weak var weakDoc: Document?
        try autoreleasepool {
            let doc = try SwiftSoup.parse("<html><body><div><p>hi</p></div></body></html>")
            weakDoc = doc
            XCTAssertNotNil(weakDoc)
        }
        XCTAssertNil(weakDoc, "select 없이 parse 만 했는데도 누수 — 원인이 selector 캐시가 아님")
    }

    func testRawDocumentDeallocates() throws {
        weak var weakDoc: Document?
        weak var weakEl: Element?
        try autoreleasepool {
            let doc = try SwiftSoup.parse(
                "<html><head><meta property='og:title' content='t'></head>" +
                "<body><div class='bbs view'><div class='cont'><p>hi</p>" +
                "<a href='https://x.com'>l</a><img src='https://x.com/a.png'></div></div></body></html>"
            )
            weakDoc = doc
            weakEl = try doc.select("p").first()
            _ = try doc.select("meta[property=og:title]").first()?.attr("content")
            _ = try doc.select("a[href]").first()
            XCTAssertNotNil(weakDoc)
            XCTAssertNotNil(weakEl)
        }
        XCTAssertNil(weakDoc, "SwiftSoup Document 가 해제되지 않음 — 라이브러리 retain cycle")
        XCTAssertNil(weakEl, "SwiftSoup Element 가 해제되지 않음")
    }
}
