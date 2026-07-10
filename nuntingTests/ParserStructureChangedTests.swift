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

    func testBobaeDeletionReturnsNotice() throws {
        let html = "<html><body><script>alert('삭제된 글 입니다.');history.back();</script></body></html>"
        assertDeletionNotice(try BobaeParser().parseDetail(html: html, post: .fixture(site: .bobae)))
    }

    func testAagagDeletionReturnsNotice() throws {
        // No AAGAG_AA.content script + deletion keyword → notice, not throw.
        let html = "<html><body>삭제되었거나 존재하지 않는 게시물입니다.</body></html>"
        assertDeletionNotice(try AagagParser().parseDetail(html: html, post: .fixture(site: .aagag)))
    }
}
