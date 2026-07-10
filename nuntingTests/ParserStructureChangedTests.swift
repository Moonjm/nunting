import XCTest
@testable import nunting

/// 회귀 가드: detail 페이지의 **핵심 본문 컨테이너**가 사라지면(=사이트 마크업
/// 변경) 모든 파서가 조용히 빈 글을 내지 않고 `ParserError.structureChanged` 를
/// 던져, 앱이 "사이트 구조가 바뀐 것 같아요" 신호를 띄우도록 통일한다. 단, 사이트가
/// 의도적으로 내려주는 "삭제/이동된 글" 안내는 throw 가 아니라 graceful notice
/// (`.text(...)` 블록) 로 유지한다 — 정상 응답이라 structureChanged 가 아니다.
final class ParserStructureChangedTests: XCTestCase {

    /// 컨테이너도 없고 삭제 키워드도 없는 "구조 깨짐" 입력.
    private let garbage = "<html><body><div>nothing here</div></body></html>"

    private func assertStructureChanged(
        _ parse: () throws -> PostDetail,
        _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try parse(), message, file: file, line: line) { error in
            guard case ParserError.structureChanged = error else {
                XCTFail("expected .structureChanged, got \(error)", file: file, line: line)
                return
            }
        }
    }

    // MARK: - throw on missing container

    func testCook82ThrowsOnMissingContainer() {
        assertStructureChanged { try Cook82Parser().parseDetail(html: garbage, post: .fixture(site: .cook82)) }
    }

    func testSLRThrowsOnMissingContainer() {
        assertStructureChanged { try SLRParser().parseDetail(html: garbage, post: .fixture(site: .slr)) }
    }

    func testDdanziThrowsOnMissingContainer() {
        assertStructureChanged { try DdanziParser().parseDetail(html: garbage, post: .fixture(site: .ddanzi)) }
    }

    func testHumorThrowsOnMissingContainer() {
        assertStructureChanged { try HumorParser().parseDetail(html: garbage, post: .fixture(site: .humor)) }
    }

    func testEtolandThrowsOnMissingContainer() {
        assertStructureChanged { try EtolandParser().parseDetail(html: garbage, post: .fixture(site: .etoland)) }
    }

    func testBobaeThrowsOnMissingContainer() {
        assertStructureChanged { try BobaeParser().parseDetail(html: garbage, post: .fixture(site: .bobae)) }
    }

    func testAagagThrowsOnMissingContentScript() {
        assertStructureChanged { try AagagParser().parseDetail(html: garbage, post: .fixture(site: .aagag)) }
    }

    // 직접 브라우징 4사이트 — 프로덕션 throw 는 있었지만 회귀 테스트가 없어,
    // 리팩터링이 조용히 빈-글 동작으로 격하시킬 수 있었다. 여기 고정.

    func testClienThrowsOnMissingContainer() {
        assertStructureChanged { try ClienParser().parseDetail(html: garbage, post: .fixture(site: .clien)) }
    }

    func testCoolenjoyThrowsOnMissingContainer() {
        assertStructureChanged { try CoolenjoyParser().parseDetail(html: garbage, post: .fixture(site: .coolenjoy)) }
    }

    func testInvenThrowsOnMissingContainer() {
        assertStructureChanged { try InvenParser().parseDetail(html: garbage, post: .fixture(site: .inven)) }
    }

    func testPpomppuThrowsOnMissingContainer() {
        assertStructureChanged { try PpomppuParser().parseDetail(html: garbage, post: .fixture(site: .ppomppu)) }
    }

    // MARK: - deletion stays graceful (no throw)

    private func assertDeletionNotice(
        _ detail: PostDetail, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(detail.blocks.plainText.contains("삭제"),
                      "삭제글은 throw 가 아니라 안내 텍스트로 떠야 한다 (got: \(detail.blocks.plainText))",
                      file: file, line: line)
    }

    func testCook82DeletionReturnsNotice() throws {
        let html = "<html><body>삭제된 게시물입니다.</body></html>"
        assertDeletionNotice(try Cook82Parser().parseDetail(html: html, post: .fixture(site: .cook82)))
    }

    func testSLRDeletionReturnsNotice() throws {
        let html = "<html><body>이동되었거나 삭제된 게시물입니다.</body></html>"
        assertDeletionNotice(try SLRParser().parseDetail(html: html, post: .fixture(site: .slr)))
    }

    func testDdanziDeletionReturnsNotice() throws {
        let html = "<html><body>삭제되었거나 존재하지 않는 글입니다.</body></html>"
        assertDeletionNotice(try DdanziParser().parseDetail(html: html, post: .fixture(site: .ddanzi)))
    }

    func testHumorDeletionReturnsNotice() throws {
        let html = "<html><body>삭제된 게시물입니다.</body></html>"
        assertDeletionNotice(try HumorParser().parseDetail(html: html, post: .fixture(site: .humor)))
    }

    func testEtolandDeletionReturnsNotice() throws {
        let html = "<html><body>삭제되거나 이동된 게시물입니다.</body></html>"
        assertDeletionNotice(try EtolandParser().parseDetail(html: html, post: .fixture(site: .etoland)))
    }

    /// 실측(2026-07-10) 이토랜드 삭제 글: 안내 문구가 body 텍스트가 아니라
    /// `__next_f.push` flight payload 안의 `alert("삭제된 게시글입니다.")` 로만
    /// 온다. SwiftSoup `text()` 는 script 내용을 제외하므로 키워드 폴백이
    /// 못 잡고 structureChanged 오탐이 났던 케이스 — raw HTML 검사로 잡아야 한다.
    func testEtolandScriptAlertDeletionReturnsNotice() throws {
        let html = #"""
        <html><body><div id="__next"></div>
        <script>self.__next_f.push([1,"6:[\"$\",\"$L1d\",null,{\"dangerouslySetInnerHTML\":{\"__html\":\"alert(\\\"삭제된 게시글입니다.\\\");history.back();if(window.opener){window.close();}\"}}]\n"])</script>
        </body></html>
        """#
        assertDeletionNotice(try EtolandParser().parseDetail(html: html, post: .fixture(site: .etoland)))
    }

    /// 실측(2026-07-10) 이토랜드 없는-글 변형: Next.js 에러 화면 문구
    /// ("페이지가 존재하지 않거나 이동되었을 수 있습니다")가 flight payload
    /// script 에만 실려 온다. 위와 같은 이유로 raw HTML 검사 대상.
    func testEtolandFlightNotFoundReturnsNotice() throws {
        let html = #"""
        <html><body><div id="__next"></div>
        <script>self.__next_f.push([1,"{\"className\":\"md:title-s\",\"children\":[\"페이지가 존재하지 않거나 이동되었을 수 있습니다.\"]}"])</script>
        </body></html>
        """#
        assertDeletionNotice(try EtolandParser().parseDetail(html: html, post: .fixture(site: .etoland)))
    }

    func testBobaeDeletionReturnsNotice() throws {
        let html = "<html><body><script>alert('삭제된 글 입니다.');history.back();</script></body></html>"
        assertDeletionNotice(try BobaeParser().parseDetail(html: html, post: .fixture(site: .bobae)))
    }

    func testAagagDeletionReturnsNotice() throws {
        // No AAGAG_AA.content script + deletion keyword → notice, not throw.
        let html = "<html><body>삭제되었거나 존재하지 않는 게시물입니다.</body></html>"
        assertDeletionNotice(try AagagParser().parseDetail(html: html, post: .fixture(site: .aagag)))
    }

    /// 실측(2026-07-10) 인벤 삭제/없는 글: 302 없이 200 으로 목록 셸 페이지가
    /// 오고(`mo-board-view` 부재), 본문 텍스트에 "요청하신 페이지를 찾을 수
    /// 없습니다." 안내가 있다. structureChanged 오탐이 아니라 notice 처리 대상.
    func testInvenNotFoundPageReturnsNotice() throws {
        let html = """
        <html><body>
        <section class='mobile-board-top-module'><h4><a>웹진</a></h4></section>
        <div class="articleError">요청하신 페이지를 찾을 수 없습니다.<br>서비스 이용에 불편을 드려 죄송합니다.</div>
        </body></html>
        """
        assertDeletionNotice(try InvenParser().parseDetail(html: html, post: .fixture(site: .inven)))
    }
}
