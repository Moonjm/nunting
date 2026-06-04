import XCTest
@testable import nunting

/// 뽐뿌 모바일 detail 은 댓글 "마지막 페이지"를 inline 으로 렌더하는데,
/// fetchAllComments 가 이를 page 1 로 오인해 그 페이지를 중복시키고 실제
/// page 1 을 누락시키던 버그 회귀 방지. (스크롤하면 같은 댓글이 다시 나옴)
final class PpomppuCommentPaginationTests: XCTestCase {
    /// 병렬 task group 의 fetcher 가 어떤 c_page 를 요청했는지 thread-safe 하게
    /// 기록(자식 task 들이 동시에 append 하므로 plain Array 는 race).
    private actor PageRecorder {
        private(set) var pages: [String] = []
        func add(_ p: String) { pages.append(p) }
    }

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

    private func cpage(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "c_page" })?.value ?? "?"
    }

    private func post(no: Int) -> Post {
        Post.fixture(
            id: "freeboard-\(no)", site: .ppomppu, boardID: "freeboard",
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_view.php?id=freeboard&no=\(no)")!)
    }

    func testDetailLastPageNotDuplicatedAndAllPagesIncluded() async throws {
        let parser = PpomppuParser()
        // detail = 마지막 페이지(3/3) inline.
        let detailHTML = page(current: 3, total: 3, ctxID: "30", content: "p3")

        let recorder = PageRecorder()
        let comments = try await parser.fetchAllComments(for: post(no: 1), detailHTML: detailHTML) { url in
            let cp = self.cpage(of: url)
            await recorder.add(cp)
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
        let requested = await recorder.pages
        XCTAssertEqual(Set(requested), ["1", "2"])
    }

    func testDetailGenuinelyPage1MultiPageFetchesRest() async throws {
        // 어떤 글은 detail 이 실제 page 1 (1/2) 일 수도 있다. 그땐 2..N 만
        // 가져오면 되고 중복이 없어야 한다(clamp/슬롯 로직의 반대쪽 케이스).
        let parser = PpomppuParser()
        let detailHTML = page(current: 1, total: 2, ctxID: "10", content: "p1")

        let recorder = PageRecorder()
        let comments = try await parser.fetchAllComments(for: post(no: 3), detailHTML: detailHTML) { url in
            let cp = self.cpage(of: url)
            await recorder.add(cp)
            return cp == "2" ? self.page(current: 2, total: 2, ctxID: "20", content: "p2") : ""
        }

        XCTAssertEqual(comments.map(\.content), ["p1", "p2"])
        let requested = await recorder.pages
        XCTAssertEqual(requested, ["2"], "detail=page1 이면 page2 만 가져옴")
    }

    func testSinglePageReusesDetailWithoutFetching() async throws {
        let parser = PpomppuParser()
        let detailHTML = page(current: 1, total: 1, ctxID: "5", content: "only")

        let recorder = PageRecorder()
        let comments = try await parser.fetchAllComments(for: post(no: 2), detailHTML: detailHTML) { url in
            await recorder.add(self.cpage(of: url))
            return ""
        }
        XCTAssertEqual(comments.map(\.content), ["only"])
        let requested = await recorder.pages
        XCTAssertTrue(requested.isEmpty, "단일 페이지는 추가 fetch 없이 detail 재사용")
    }
}
