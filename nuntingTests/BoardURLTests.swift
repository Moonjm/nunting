import XCTest
@testable import nunting

/// Black-box tests for `Board.url(filter:search:page:)` covering the
/// site-specific paging conventions (Clien zero-based offsets, Clien
/// search-base swap, Inven `p`, Coolenjoy/Ppomppu/Aagag `page`) and
/// the filter `replacementPath` mode used by aagag's `이슈모음` toggle.
///
/// These exist primarily as a regression net for the URL construction
/// path: a wrong query-item key or a subtle off-by-one in Clien's
/// page math is a "the search returns nothing and nobody knows why"
/// class of bug that no parser test would catch.
final class BoardURLTests: XCTestCase {

    // MARK: - Plain list URLs

    func testClienNewsPlainListURL() {
        let url = Board.clienNews.url
        XCTAssertEqual(url.absoluteString, "https://www.clien.net/service/board/news")
    }

    func testInvenMaplePlainListURL() {
        let url = Board.invenMaple.url
        XCTAssertEqual(url.absoluteString, "https://m.inven.co.kr/board/maple/5974")
    }

    func testCoolenjoyJirumPlainListURL() {
        let url = Board.coolenjoyJirum.url
        XCTAssertEqual(url.absoluteString, "https://coolenjoy.net/bbs/jirum")
    }

    func testAagagPlainListURL() {
        let url = Board.aagag.url
        XCTAssertEqual(
            url.absoluteString,
            "https://aagag.com/mirror/?site=clien%7Cppomppu%7C82cook%7Cbobae%7Chumor%7Cddanzi%7Cslrclub%7Cdamoang&select=multi"
        )
    }

    // MARK: - Paging conventions

    func testClienNewsPageTwoUsesZeroBasedOffset() {
        // Clien lists are zero-based: page 2 → po=1
        let url = Board.clienNews.url(filter: nil, search: nil, page: 2)
        XCTAssertEqual(url.query, "po=1")
    }

    func testClienNewsPageOneIsBareURL() {
        // page 1 must not append po=0 (would be a redundant param and noise)
        let url = Board.clienNews.url(filter: nil, search: nil, page: 1)
        XCTAssertNil(url.query)
    }

    func testInvenMaplePageTwoUsesP() {
        let url = Board.invenMaple.url(filter: nil, search: nil, page: 2)
        XCTAssertEqual(url.query, "p=2")
    }

    func testCoolenjoyJirumPageTwoUsesPage() {
        let url = Board.coolenjoyJirum.url(filter: nil, search: nil, page: 2)
        XCTAssertEqual(url.query, "page=2")
    }

    func testPpomppuMainPageTwoUsesPage() {
        // Ppomppu's path bakes `id=ppomppu` into the path itself
        // (`/new/bbs_list.php?id=ppomppu`), so the merged query has
        // both items — assert by item map, not raw query string.
        let url = Board.ppomppuMain.url(filter: nil, search: nil, page: 2)
        let items = queryItems(of: url)
        XCTAssertEqual(items["id"], "ppomppu")
        XCTAssertEqual(items["page"], "2")
    }

    // MARK: - Filters

    func testInvenMapleFilterChuMergesQueryItem() {
        let chu = Board.invenMaple.filters.first { $0.id == "chu" }!
        let url = Board.invenMaple.url(filter: chu, search: nil, page: nil)
        XCTAssertEqual(url.query, "my=chu")
    }

    func testInvenMapleFilterChuWithPageMergesBoth() {
        let chu = Board.invenMaple.filters.first { $0.id == "chu" }!
        let url = Board.invenMaple.url(filter: chu, search: nil, page: 2)
        let items = queryItems(of: url)
        XCTAssertEqual(items["my"], "chu")
        XCTAssertEqual(items["p"], "2")
    }

    func testAagagIssueFilterUsesReplacementPath() {
        let issue = Board.aagag.filters.first { $0.id == "issue" }!
        let url = Board.aagag.url(filter: issue, search: nil, page: nil)
        XCTAssertEqual(url.absoluteString, "https://aagag.com/issue/")
    }

    func testAagagIssueFilterPageTwo() {
        let issue = Board.aagag.filters.first { $0.id == "issue" }!
        let url = Board.aagag.url(filter: issue, search: nil, page: 2)
        XCTAssertEqual(url.absoluteString, "https://aagag.com/issue/?page=2")
    }

    // MARK: - Search

    func testClienNewsSearchSwapsBaseAndPath() {
        // Search uses m.clien.net, /service/search path, and prefix items
        // (boardCd extracted from the original board path).
        let url = Board.clienNews.url(filter: nil, search: "apple", page: nil)
        XCTAssertEqual(url.host, "m.clien.net")
        XCTAssertEqual(url.path, "/service/search")
        let items = queryItems(of: url)
        XCTAssertEqual(items["boardCd"], "news")
        XCTAssertEqual(items["isBoard"], "true")
        XCTAssertEqual(items["sort"], "recency")
        XCTAssertEqual(items["q"], "apple")
    }

    func testClienNewsSearchPageTwoUsesPNotPo() {
        // In search mode Clien switches paging from `po` to `p`, still
        // zero-based so page 2 → p=1.
        let url = Board.clienNews.url(filter: nil, search: "apple", page: 2)
        let items = queryItems(of: url)
        XCTAssertEqual(items["p"], "1")
        XCTAssertNil(items["po"])
    }

    func testInvenMapleSearchUsesSvalueAndStypeSubject() {
        let url = Board.invenMaple.url(filter: nil, search: "메이플", page: nil)
        let items = queryItems(of: url)
        XCTAssertEqual(items["stype"], "subject")
        XCTAssertEqual(items["svalue"], "메이플")
    }

    func testInvenMapleSearchPageTwoStaysOnP() {
        // Inven uses `p` in both list and search modes and stays 1-based.
        let url = Board.invenMaple.url(filter: nil, search: "메이플", page: 2)
        let items = queryItems(of: url)
        XCTAssertEqual(items["p"], "2")
    }

    func testEmptySearchQueryStripsToListMode() {
        // Whitespace-only / empty search must not flip into search mode —
        // otherwise the user sees a redirect to /service/search with no
        // query terms, which most sites surface as an empty result page.
        let url = Board.clienNews.url(filter: nil, search: "   ", page: nil)
        XCTAssertEqual(url.absoluteString, "https://www.clien.net/service/board/news")
    }

    // MARK: - Helpers

    private func queryItems(of url: URL) -> [String: String] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems
        else { return [:] }
        var result: [String: String] = [:]
        for item in items {
            result[item.name] = item.value
        }
        return result
    }
}
