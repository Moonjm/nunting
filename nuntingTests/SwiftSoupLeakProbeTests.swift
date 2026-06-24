import XCTest
import SwiftSoup
@testable import nunting

/// 진단(임시): 파싱한 SwiftSoup Document/Element 가 스코프를 벗어나면 실제로
/// 해제되는지 확인. Instruments 가 post-open 마다 SwiftSoup DOM(~676 Element)
/// 누적을 보여줘, 라이브러리 자체가 doc 를 못 푸는지(=cycle) vs 앱이 잡는지를
/// 가른다. 결과 확인 후 제거.
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

    func testPpomppuParseDetailDeallocatesDoc() throws {
        let html = """
        <html><head><meta property="og:title" content="전체 제목"></head><body>
        <div class="bbs view"><h4><span class="hi">2026-06-24 15:34</span></h4>
        <div class="cont"><p>본문</p><img src="https://x.com/a.png"></div></div>
        </body></html>
        """
        let post = Post(id: "ppomppu-1", site: .ppomppu, boardID: "ppomppu",
                        title: "t", author: "a", date: nil, dateText: "", commentCount: 0,
                        url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=1")!)
        // parseDetail 은 값 타입만 반환하므로, 내부 doc 가 남는지 보려면 메모리
        // 동작을 직접 못 잡는다 — 여기선 호출이 크래시/누수 없이 끝나는지와
        // fullTitle 추출만 핀(보강은 raw 테스트가 담당).
        let detail = try PpomppuParser().parseDetail(html: html, post: post)
        XCTAssertEqual(detail.fullTitle, "전체 제목")
    }
}
