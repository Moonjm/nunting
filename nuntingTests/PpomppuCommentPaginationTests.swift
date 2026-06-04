import XCTest
@testable import nunting

/// 뽐뿌 모바일 detail 은 댓글 "마지막 페이지"를 inline 으로 렌더하는데,
/// fetchAllComments 가 이를 page 1 로 오인해 그 페이지를 중복시키고 실제
/// page 1 을 누락시키던 버그 회귀 방지. (스크롤하면 같은 댓글이 다시 나옴)
final class PpomppuCommentPaginationTests: XCTestCase {
    /// current/total + 댓글 1개를 가진 최소 뽐뿌 댓글 페이지 HTML.
    private func page(current: Int, total: Int, ctxID: String, content: String) -> String {
        """
        <html><body>
        <div class="cmt-topInfo"><span class="cmt-total">159</span>\
        <span class="cmt-page"><a class="prevPage"></a>\(current) / \(total)\
        <a class="nextPage"></a></span></div>
        <div class="cmAr">
          <div class="sect-cmt" data-depth="0"><div id="ctx_\(ctxID)">\(content)</div></div>
        </div>
        </body></html>
        """
    }

    func testDetailLastPageNotDuplicatedAndAllPagesIncluded() async throws {
        let parser = PpomppuParser()
        let post = Post.fixture(
            id: "freeboard-1", site: .ppomppu, boardID: "freeboard",
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=freeboard&no=1")!)

        // detail = 마지막 페이지(3/3) inline.
        let detailHTML = page(current: 3, total: 3, ctxID: "30", content: "p3")

        var requested: [String] = []
        let comments = try await parser.fetchAllComments(for: post, detailHTML: detailHTML) { url in
            let cp = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "c_page" })?.value ?? "?"
            requested.append(cp)
            switch cp {
            case "1": return self.page(current: 1, total: 3, ctxID: "10", content: "p1")
            case "2": return self.page(current: 2, total: 3, ctxID: "20", content: "p2")
            case "3": return self.page(current: 3, total: 3, ctxID: "30", content: "p3")
            default: return ""
            }
        }

        // 1·2·3 순서대로, 중복/누락 없이.
        XCTAssertEqual(comments.map(\.content), ["p1", "p2", "p3"])
        XCTAssertEqual(Set(comments.map(\.id)).count, 3, "중복 댓글 없어야 함")
        // detail(=page3)은 재사용 → c_page=3 안 가져오고 빠진 1·2 만 fetch.
        XCTAssertEqual(Set(requested), ["1", "2"])
    }

    func testSinglePageReusesDetailWithoutFetching() async throws {
        let parser = PpomppuParser()
        let post = Post.fixture(
            id: "freeboard-2", site: .ppomppu, boardID: "freeboard",
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=freeboard&no=2")!)
        let detailHTML = page(current: 1, total: 1, ctxID: "5", content: "only")

        var fetched = false
        let comments = try await parser.fetchAllComments(for: post, detailHTML: detailHTML) { _ in
            fetched = true
            return ""
        }
        XCTAssertEqual(comments.map(\.content), ["only"])
        XCTAssertFalse(fetched, "단일 페이지는 추가 fetch 없이 detail 재사용")
    }
}
