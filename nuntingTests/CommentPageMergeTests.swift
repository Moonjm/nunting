import XCTest
@testable import nunting

/// `BoardParser.mergeCommentPages` 계약 — 뽐뿌/보배/딴지/쿨엔조이의
/// fetchAllComments 에 복붙돼 있던 "댓글 페이지 병렬 fetch + 페이지 단위
/// 실패 흡수 + 취소 재던짐 + 페이지 순 병합" 골격의 공통 헬퍼.
/// (#89/#90 류 수정을 매번 4곳에 동시 적용해야 했던 로직.)
final class CommentPageMergeTests: XCTestCase {
    private nonisolated func comment(_ tag: String) -> PostComment {
        PostComment(id: tag, author: "a", dateText: "", content: tag, likeCount: 0, isReply: false)
    }

    /// extension 헬퍼라 아무 BoardParser 채택 타입으로 접근.
    private let parser = PpomppuParser()

    func testMergesPagesInPageOrderWithInlineAtItsIndex() async throws {
        // inline = 마지막 페이지(3/3) — 뽐뿌/보배의 "detail 은 댓글 마지막
        // 페이지를 inline 렌더" 케이스. 1,2 만 fetch 하고 1..3 순서로 병합.
        let merged = try await parser.mergeCommentPages(
            total: 3, inlinePage: 3, inline: [comment("p3")]
        ) { page in
            XCTAssertNotEqual(page, 3, "inline 페이지는 재요청하면 안 됨")
            return [self.comment("p\(page)")]
        }
        XCTAssertEqual(merged.map(\.content), ["p1", "p2", "p3"])
    }

    func testSinglePageReturnsInlineWithoutFetching() async throws {
        let merged = try await parser.mergeCommentPages(
            total: 1, inlinePage: 1, inline: [comment("only")]
        ) { _ in
            XCTFail("total <= 1 이면 fetch 없어야 함")
            return []
        }
        XCTAssertEqual(merged.map(\.content), ["only"])
    }

    func testFailedPageIsSkippedNotFatal() async throws {
        // 단일 페이지 실패가 댓글 전체를 유실시키면 안 됨 (#90 회귀의 골격).
        struct PageError: Error {}
        let merged = try await parser.mergeCommentPages(
            total: 4, inlinePage: 1, inline: [comment("p1")]
        ) { page in
            if page == 3 { throw PageError() }
            return [self.comment("p\(page)")]
        }
        XCTAssertEqual(merged.map(\.content), ["p1", "p2", "p4"])
    }

    func testCancellationRethrowsInsteadOfReturningPartial() async {
        // 페이지 실패 흡수(do/catch)가 CancellationError 까지 삼켜 부분 댓글이
        // 정상 완료처럼 popped 뷰에 붙으면 안 됨 — 취소는 다시 던져야 한다.
        let task = Task { [parser] in
            try await parser.mergeCommentPages(
                total: 3, inlinePage: 1, inline: []
            ) { page in
                // 취소돼도 정상 반환해 "흡수된 취소" 상황을 재현.
                try? await Task.sleep(nanoseconds: 50_000_000)
                return [self.comment("p\(page)")]
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("취소된 로드는 부분 결과 대신 throw 해야 함")
        } catch {
            XCTAssertTrue(error is CancellationError, "CancellationError 여야 함: \(error)")
        }
    }
}
