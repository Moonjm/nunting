import XCTest
@testable import nunting

/// `BoardParser.mergeCommentPages` 계약 — 뽐뿌/보배/딴지/쿨엔조이의
/// fetchAllComments 에 복붙돼 있던 "댓글 페이지 병렬 fetch + 페이지 단위
/// 실패 흡수 + 취소 재던짐 + 페이지 순 병합" 골격의 공통 헬퍼.
/// (#89/#90 류 수정을 매번 4곳에 동시 적용해야 했던 로직.)
// @MainActor: 취소 테스트의 `Task.detached + await task.value` 조합을
// nonisolated 컨텍스트에서 쓰면 Swift 6 region 체커가 "please file a bug" 로
// 컴파일을 막는다(체커 미지원 패턴). main actor 로 올리면 통과하며, 검증
// 대상(mergeCommentPages 의 취소 재던짐)의 시맨틱은 동일.
@MainActor
final class CommentPageMergeTests: XCTestCase {
    // static: fetchPage 는 @Sendable 클로저 — 인스턴스 헬퍼면 non-Sendable
    // self 캡처로 Swift 6 모드에서 에러. 순수 팩토리라 타입 메서드로 충분.
    nonisolated private static func comment(_ tag: String) -> PostComment {
        PostComment(id: tag, author: "a", dateText: "", content: tag, likeCount: 0, isReply: false)
    }

    /// extension 헬퍼라 아무 BoardParser 채택 타입으로 접근.
    nonisolated private static let parser = PpomppuParser()

    func testMergesPagesInPageOrderWithInlineAtItsIndex() async throws {
        // inline = 마지막 페이지(3/3) — 뽐뿌/보배의 "detail 은 댓글 마지막
        // 페이지를 inline 렌더" 케이스. 1,2 만 fetch 하고 1..3 순서로 병합.
        let merged = try await Self.parser.mergeCommentPages(
            total: 3, inlinePage: 3, inline: [Self.comment("p3")]
        ) { page in
            XCTAssertNotEqual(page, 3, "inline 페이지는 재요청하면 안 됨")
            return [Self.comment("p\(page)")]
        }
        XCTAssertEqual(merged.map(\.content), ["p1", "p2", "p3"])
    }

    func testSinglePageReturnsInlineWithoutFetching() async throws {
        let merged = try await Self.parser.mergeCommentPages(
            total: 1, inlinePage: 1, inline: [Self.comment("only")]
        ) { _ in
            XCTFail("total <= 1 이면 fetch 없어야 함")
            return []
        }
        XCTAssertEqual(merged.map(\.content), ["only"])
    }

    func testFailedPageIsSkippedNotFatal() async throws {
        // 단일 페이지 실패가 댓글 전체를 유실시키면 안 됨 (#90 회귀의 골격).
        struct PageError: Error {}
        let merged = try await Self.parser.mergeCommentPages(
            total: 4, inlinePage: 1, inline: [Self.comment("p1")]
        ) { page in
            if page == 3 { throw PageError() }
            return [Self.comment("p\(page)")]
        }
        XCTAssertEqual(merged.map(\.content), ["p1", "p2", "p4"])
    }

    func testEmptyPageBehavesLikeMissingPage() async throws {
        // 페이지 URL 을 만들 수 없는 경우(뽐뿌/보배 클로저의 `return []`)는
        // fetch 실패로 누락된 페이지와 동일하게 — 그 페이지만 비고 병합 유지.
        let merged = try await Self.parser.mergeCommentPages(
            total: 3, inlinePage: 1, inline: [Self.comment("p1")]
        ) { page in
            page == 2 ? [] : [Self.comment("p\(page)")]
        }
        XCTAssertEqual(merged.map(\.content), ["p1", "p3"])
    }

    func testCancellationRethrowsInsteadOfReturningPartial() async {
        // 페이지 실패 흡수(do/catch)가 CancellationError 까지 삼켜 부분 댓글이
        // 정상 완료처럼 popped 뷰에 붙으면 안 됨 — 취소는 다시 던져야 한다.
        let task = Task.detached { await mergeRethrowsCancellation() }
        task.cancel()
        let rethrew = await task.value
        XCTAssertTrue(rethrew, "취소된 로드는 부분 결과 대신 CancellationError 를 던져야 함")
    }
}

/// 취소 테스트용 자유 함수: 각 페이지가 50ms 걸리고, 취소돼도 정상 반환해
/// "흡수된 취소" 상황을 재현한다. 판정(CancellationError 여부)까지 안에서
/// 끝내 Bool 만 반환한다. 클래스 밖에 두는 이유: 테스트 클래스의 static
/// (Self 캡처)을 Task 클로저에서 부르는 형태를 Swift 6(6.3.3) region 체커가
/// "please file a bug" 로 컴파일 거부 — self/Self 관여가 없는 자유 함수는 통과.
private func mergeRethrowsCancellation() async -> Bool {
    do {
        _ = try await PpomppuParser().mergeCommentPages(
            total: 3, inlinePage: 1, inline: []
        ) { page in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return [PostComment(id: "p\(page)", author: "a", dateText: "", content: "p\(page)", likeCount: 0, isReply: false)]
        }
        return false
    } catch is CancellationError {
        return true
    } catch {
        return false
    }
}
