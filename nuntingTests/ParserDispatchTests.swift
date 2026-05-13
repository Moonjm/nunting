import XCTest
@testable import nunting
import NuntingCore

/// Regression net for the cross-module protocol witness binding trap documented at
/// `Shared/Sources/NuntingCore/BoardParser.swift` top.
///
/// 핵심: `let parser: any BoardParser = EtolandParser()`처럼 existential을 통해 호출하면
/// Swift는 PWT(protocol witness table)를 거쳐 dispatch한다. concrete `parser.fetchAllComments(...)`
/// 호출은 static dispatch라 witness binding이 깨져도 우연히 통과하므로, 이 트랩의 진짜
/// regression net은 existential을 통한 동적 dispatch뿐이다.
///
/// 이 테스트가 fail하면: 누군가 `Shared/Package.swift`에서
/// `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`를 제거했거나
/// iOS 타겟의 `SWIFT_APPROACHABLE_CONCURRENCY` 설정이 변경됐을 가능성이 높다.
/// BoardParser.swift 상단의 "Closure isolation contract" 절을 참고.
final class ParserDispatchTests: XCTestCase {
    /// EtolandParser의 inline-skip 경로가 existential 호출에서도 살아있는지 확인.
    /// witness binding이 깨지면 default extension impl이 dispatch되어 fetcher가
    /// 호출되고(fetched=true), 이 테스트가 fail한다.
    func testEtolandFetchAllCommentsDispatchesViaExistential() async throws {
        let parser: any BoardParser = EtolandParser()
        let post = Post(
            id: "x",
            site: .etoland,
            boardID: "aagag",
            title: "t",
            author: "",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://etoland.co.kr/b/etohumor07/view/-1")!
        )
        let inlineHTML = #"<script>self.__next_f.push([1,"...\"data\":{\"comments\":[{}]}..."])</script>"#

        nonisolated(unsafe) var fetched = false
        let comments = try await parser.fetchAllComments(
            for: post,
            detailHTML: inlineHTML
        ) { _ in
            fetched = true
            return ""
        }
        XCTAssertTrue(comments.isEmpty)
        XCTAssertFalse(
            fetched,
            "EtolandParser.fetchAllComments witness가 default extension impl로 바뀌었음 — "
                + "BoardParser.swift 상단의 Closure isolation contract 절 참고"
        )
    }

    /// 다른 cross-module 파서(Coolenjoy)도 같은 dispatch 경로로 검증해, 트랩이 특정
    /// 파서에만 적용되지 않음을 확인. Coolenjoy는 injected fetcher를 사용해 첫 페이지를
    /// 로드한 뒤 parseComments로 댓글을 추출한다. fetcher가 던지면 throw로 propagate되어
    /// witness가 concrete impl로 dispatch됐음을 증명한다(default impl이라면 nil
    /// commentsURL로 throw 없이 []을 반환).
    func testCoolenjoyFetchAllCommentsDispatchesViaExistential() async throws {
        struct SentinelError: Error {}
        let parser: any BoardParser = CoolenjoyParser()
        let post = Post(
            id: "x",
            site: .coolenjoy,
            boardID: "jirum",
            title: "t",
            author: "",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://coolenjoy.net/bbs/jirum/12345")!
        )

        do {
            _ = try await parser.fetchAllComments(for: post, detailHTML: nil) { _ in
                throw SentinelError()
            }
            XCTFail(
                "CoolenjoyParser.fetchAllComments witness가 default extension impl로 바뀌었음 — "
                    + "default impl은 commentsURL=nil이라 fetcher를 호출하지 않고 [] 반환"
            )
        } catch is SentinelError {
            // 예상 경로: concrete impl이 fetcher를 호출해 throw가 전파됨
        }
    }
}
