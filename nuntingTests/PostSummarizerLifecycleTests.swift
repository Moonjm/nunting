import XCTest
@testable import nunting

/// 요약 라이프사이클 레이스 회귀 테스트 (Codex 리뷰 P1 2건).
/// 오버레이 keep-alive 로 summarizer 인스턴스가 글 전환을 넘어 살아남는
/// 구조라, (1) 이전 글 detail 로 새 글 요약을 만들거나 (2) reset 이후에도
/// 낡은 생성 태스크가 상태를 밀어 넣는 레이스가 실제로 성립한다.
/// 생성부는 `generate` 시임으로 대체 — 모델 없이 결정적으로 검증한다.
@MainActor
final class PostSummarizerLifecycleTests: XCTestCase {

    private func detail(postID: String, body: String = "본문") -> PostDetail {
        PostDetail(
            post: .fixture(id: postID),
            blocks: [.text(body)],
            fullDateText: nil, viewCount: nil, source: nil, comments: []
        )
    }

    /// 호출 횟수를 세는 즉답 생성 시임.
    private final class GenerateSpy: @unchecked Sendable {
        var calls = 0
        var result = "요약 결과"
    }

    private func summarizer(
        spy: GenerateSpy,
        beforeReturn: (@MainActor () async -> Void)? = nil
    ) -> PostSummarizer {
        PostSummarizer(
            generate: { _, onSnapshot in
                spy.calls += 1
                await onSnapshot("요약")
                if let beforeReturn { await beforeReturn() }
                return spy.result
            },
            pollInterval: .milliseconds(5),
            maxPolls: 3
        )
    }

    // MARK: - P1-1: 이전 글 detail 로 새 글을 요약/캐시하면 안 된다

    func testStaleDetailFromPreviousPostIsNeverSummarized() async {
        let spy = GenerateSpy()
        let sut = summarizer(spy: spy)
        // 로더가 이전 글 detail 만 계속 노출하는 상황(새 로드 지연).
        await sut.summarizeIfNeeded(postID: "new-post") { self.detail(postID: "old-post") }

        XCTAssertEqual(spy.calls, 0, "요청 글과 다른 detail 로는 생성하지 않는다")
        XCTAssertEqual(sut.state, .idle, "포기 시 idle 로 되돌아간다")

        // 이후 올바른 detail 이 오면 정상 생성 + postID 캐시.
        await sut.summarizeIfNeeded(postID: "new-post") { self.detail(postID: "new-post") }
        XCTAssertEqual(spy.calls, 1)
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }

    func testLateMatchingDetailIsPickedUpWithinPollWindow() async {
        let spy = GenerateSpy()
        let sut = summarizer(spy: spy)
        // 처음엔 이전 글, 두 번째 폴부터 요청 글 — 로드 완료를 폴링으로 잡는다.
        nonisolated(unsafe) var polls = 0
        await sut.summarizeIfNeeded(postID: "p2") {
            polls += 1
            return self.detail(postID: polls >= 2 ? "p2" : "p1")
        }
        XCTAssertEqual(spy.calls, 1, "요청 글 detail 이 커밋되면 생성한다")
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }

    // MARK: - P1-2: reset 이후 낡은 태스크는 상태/캐시를 쓰지 못한다

    func testResetDuringGenerationDiscardsStaleResult() async {
        let spy = GenerateSpy()
        nonisolated(unsafe) var sutRef: PostSummarizer?
        nonisolated(unsafe) var resetOnce = false
        let sut = summarizer(spy: spy, beforeReturn: {
            // 첫 생성 도중에만 글 전환(reset) 발생 — 두 번째(재생성)는 정상 완료.
            guard !resetOnce else { return }
            resetOnce = true
            sutRef?.reset()
        })
        sutRef = sut

        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }

        XCTAssertEqual(sut.state, .idle, "reset 이후 낡은 done 이 상태를 덮으면 안 된다")

        // 캐시도 오염되지 않아야 한다 — 재진입 시 새로 생성.
        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        XCTAssertEqual(spy.calls, 2, "낡은 결과는 캐시되지 않으므로 재생성")
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }

    func testResetDuringDetailWaitAbandonsQuietly() async {
        let spy = GenerateSpy()
        nonisolated(unsafe) var sutRef: PostSummarizer?
        nonisolated(unsafe) var polls = 0
        let sut = summarizer(spy: spy)
        sutRef = sut

        // detail 이 영영 안 맞는 상황에서 폴링 도중 reset — 생성 없이 종료,
        // idle 상태 유지(낡은 태스크의 사후 상태 쓰기 없음).
        await sut.summarizeIfNeeded(postID: "p9") {
            polls += 1
            if polls == 2 { sutRef?.reset() }
            return self.detail(postID: "other")
        }
        XCTAssertEqual(spy.calls, 0)
        XCTAssertEqual(sut.state, .idle)
    }

    // MARK: - 캐시 정상 경로

    func testCacheRestoresWithoutRegeneration() async {
        let spy = GenerateSpy()
        let sut = summarizer(spy: spy)
        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        XCTAssertEqual(spy.calls, 1)

        sut.reset() // 글 전환 후 재진입
        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        XCTAssertEqual(spy.calls, 1, "재진입은 캐시 복원 — 재생성 없음")
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }
}
