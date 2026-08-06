import XCTest
@testable import nunting

/// 회귀 가드: Etoland 댓글 API 응답이 깨졌을 때(디코드 실패 / status 불일치)
/// `fetchAllComments` 가 `[]` 로 뭉개지 않고 `ParserError` 를 던져,
/// PostDetailLoader 의 Result 분류가 실패를 잡아 재시도 배너를 띄우도록 한다.
/// 단, status 성공인데 댓글만 없는 정상 글은 throw 가 아니라 `[]` 로 유지한다
/// (헛배너 방지).
final class EtolandCommentErrorTests: XCTestCase {
    private let parser = EtolandParser()
    // commentsAPIURL 이 nil 을 반환하지 않도록 `/b/<boTable>/view/<slug>` 형태.
    private let post = Post.fixture(
        site: .etoland,
        url: URL(string: "https://etoland.co.kr/b/free/view/12345")!
    )

    private func assertStructureChanged(
        _ body: String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await parser.fetchAllComments(for: post, detailHTML: nil) { _ in body }
            XCTFail("깨진 응답은 throw 해야 함", file: file, line: line)
        } catch {
            guard case ParserError.structureChanged = error else {
                XCTFail("expected .structureChanged, got \(error)", file: file, line: line)
                return
            }
        }
    }

    func testThrowsOnUndecodableJSON() async {
        await assertStructureChanged("not json at all")
    }

    func testThrowsOnErrorStatus() async {
        await assertStructureChanged(#"{"status":"ETOCD500000","data":null}"#)
    }

    func testReturnsEmptyForGenuinelyNoComments() async throws {
        // status 성공 + comments 없음 = 진짜 댓글 없는 글 → throw 아님.
        let comments = try await parser.fetchAllComments(
            for: post, detailHTML: nil
        ) { _ in #"{"status":"ETOCD200000","data":{"comments":null}}"# }
        XCTAssertTrue(comments.isEmpty)
    }

    func testInlineWonPathReturnsEmptyWithoutFetching() async throws {
        // detailHTML 에 디코드 가능한 SSR 댓글 배열이 있으면 네트워크 fetch
        // 없이 즉시 []. (마커만 있고 디코드가 안 되면 폴백을 타야 한다.)
        // flight 스크립트(`__next_f.push`) 안이어야 인라인으로 인정된다 —
        // 그 밖의 텍스트는 본문일 수 있어 후보에서 제외한다.
        let html = #"<script>self.__next_f.push([1,"{\"commentList\":[{\"commentId\":1}],\"commentListPagination\":{\"page\":1}}"])</script>"#
        let comments = try await parser.fetchAllComments(
            for: post, detailHTML: html
        ) { _ in
            XCTFail("인라인 우선 경로는 fetch 하면 안 됨")
            return ""
        }
        XCTAssertTrue(comments.isEmpty)
    }
}
