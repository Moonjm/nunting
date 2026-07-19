import XCTest
@testable import nunting

/// 요약 라이프사이클 레이스 회귀 테스트 (Codex 리뷰 P1 2건).
/// 오버레이 keep-alive 로 summarizer 인스턴스가 글 전환을 넘어 살아남는
/// 구조라, (1) 이전 글 detail 로 새 글 요약을 만들거나 (2) reset 이후에도
/// 낡은 생성 태스크가 상태를 밀어 넣는 레이스가 실제로 성립한다.
/// 생성부는 `generate` 시임으로 대체 — 모델 없이 결정적으로 검증한다.
@MainActor
final class PostSummarizerLifecycleTests: XCTestCase {

    private func detail(
        postID: String,
        body: String = "본문",
        commentCount: Int = 0,
        comments: [PostComment] = []
    ) -> PostDetail {
        PostDetail(
            post: .fixture(id: postID, commentCount: commentCount),
            blocks: [.text(body)],
            fullDateText: nil, viewCount: nil, source: nil, comments: comments
        )
    }

    /// 호출 횟수·프롬프트를 기록하는 즉답 생성 시임.
    private final class GenerateSpy: @unchecked Sendable {
        var calls = 0
        var prompts: [String] = []
        var result = "요약 결과"
    }

    private func summarizer(
        spy: GenerateSpy,
        beforeReturn: (@MainActor () async -> Void)? = nil
    ) -> PostSummarizer {
        PostSummarizer(
            generate: { prompt, onSnapshot in
                spy.calls += 1
                spy.prompts.append(prompt)
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

    // MARK: - P1: 외부 reset 순서에 의존하지 않는 글 전환

    /// 뷰의 reset 태스크와 카드 태스크는 실행 순서가 보장되지 않는다 —
    /// reset 이 아직 안 불린 상태(이전 글 done)에서 새 글 태스크가 먼저
    /// 돌아도, postID 변화를 자체 감지해 전환하고 생성해야 한다.
    /// (기존엔 non-idle 을 보고 반환 → 이후 reset → 재실행 없음 → "요약 중"
    /// 멈춤.)
    func testPostSwitchWithoutExternalResetStillSummarizes() async {
        let spy = GenerateSpy()
        let sut = summarizer(spy: spy)
        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        XCTAssertEqual(sut.state, .done("요약 결과"))

        // reset 없이 곧장 다음 글 — 자체 전환으로 생성돼야 한다.
        await sut.summarizeIfNeeded(postID: "p2") { self.detail(postID: "p2") }
        XCTAssertEqual(spy.calls, 2)
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }

    // MARK: - P2: 새로고침 무효화

    func testInvalidateDropsCacheAndAllowsRegeneration() async {
        let spy = GenerateSpy()
        let sut = summarizer(spy: spy)
        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        XCTAssertEqual(spy.calls, 1)

        // pull-to-refresh — 본문/댓글이 바뀌었을 수 있으니 캐시 무효화 후 재생성.
        sut.invalidate(postID: "p1")
        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        XCTAssertEqual(spy.calls, 2, "무효화 후엔 캐시 대신 재생성")
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }

    // MARK: - P2: 재시도 성공도 캐시

    func testSuccessfulRetryPopulatesCache() async {
        let spy = GenerateSpy()
        nonisolated(unsafe) var failFirst = true
        let sut = PostSummarizer(
            generate: { _, onSnapshot in
                spy.calls += 1
                if failFirst { failFirst = false; throw NSError(domain: "gen", code: 1) }
                await onSnapshot("요약")
                return spy.result
            },
            pollInterval: .milliseconds(5),
            maxPolls: 3
        )

        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        guard case .failed = sut.state else { return XCTFail("첫 생성은 실패해야 함") }

        await sut.retry(detail: detail(postID: "p1"))
        XCTAssertEqual(sut.state, .done("요약 결과"))

        // 다른 글 갔다 재진입 — 재시도 성공본이 캐시에서 복원돼야 한다.
        sut.reset()
        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        XCTAssertEqual(spy.calls, 2, "재시도 성공이 캐시됐으므로 재생성 없음")
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }

    // MARK: - P2: 댓글 병합 대기

    /// 목록이 댓글 존재(commentCount>0)를 예고했는데 첫 매칭 detail 에
    /// 댓글이 아직 병합 전이면, 본문만으로 확정하지 말고 폴 윈도 안에서
    /// 병합을 기다렸다가 댓글 포함 프롬프트로 생성해야 한다.
    func testWaitsForPromisedCommentsBeforeGenerating() async {
        let spy = GenerateSpy()
        let sut = summarizer(spy: spy)
        nonisolated(unsafe) var polls = 0
        await sut.summarizeIfNeeded(postID: "p1") {
            polls += 1
            // 1번째 폴: 본문만(댓글 leg 미도착) → 2번째 폴부터 댓글 병합.
            return self.detail(
                postID: "p1", commentCount: 1,
                comments: polls >= 2
                    ? [PostComment(id: "c1", author: "댓글러", dateText: "", content: "베스트 반응", likeCount: 5, isReply: false)]
                    : []
            )
        }
        XCTAssertEqual(spy.calls, 1)
        XCTAssertTrue(
            spy.prompts[0].contains("베스트 반응"),
            "댓글 병합을 기다렸다가 댓글 포함 프롬프트로 생성 (got: \(spy.prompts[0].suffix(80)))")
    }

    /// 댓글 leg 가 끝내 실패하면(윈도 소진) 본문만으로라도 생성한다 —
    /// 댓글 대기가 요약 자체를 굶기면 안 된다.
    func testExhaustedCommentWaitFallsBackToBodyOnly() async {
        let spy = GenerateSpy()
        let sut = summarizer(spy: spy)
        await sut.summarizeIfNeeded(postID: "p1") {
            self.detail(postID: "p1", commentCount: 3, comments: [])
        }
        XCTAssertEqual(spy.calls, 1, "윈도 소진 후 본문만으로 생성")
        XCTAssertFalse(spy.prompts[0].contains("베스트 댓글"))
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }

    // MARK: - 취소 후 재진입

    /// 폴링 중 .task 가 취소되면(긴 글→짧은 글 전환) streaming("") 이 남아,
    /// 같은 글 재진입 시 non-idle 가드에 막혀 "요약 중…" 이 영구 표시되던
    /// 케이스 — 취소 시 현재 세대면 idle 로 복원해야 재진입 태스크가 돈다.
    func testCancellationDuringPollRestoresIdleForReentry() async {
        let spy = GenerateSpy()
        let sut = PostSummarizer(
            generate: { _, onSnapshot in
                spy.calls += 1
                await onSnapshot("요약")
                return spy.result
            },
            pollInterval: .milliseconds(50),
            maxPolls: 10
        )
        let task = Task { @MainActor in
            await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        }
        // 폴 sleep 진입 직후 취소 — 카드 언마운트(짧은 글로 전환) 시뮬레이션.
        try? await Task.sleep(for: .milliseconds(10))
        task.cancel()
        await task.value

        XCTAssertEqual(sut.state, .idle, "취소된 태스크가 streaming 을 남기면 안 된다")

        // 같은 글 재진입 — currentPostID 불변이어도 idle 이므로 생성된다.
        await sut.summarizeIfNeeded(postID: "p1") { self.detail(postID: "p1") }
        XCTAssertEqual(spy.calls, 1)
        XCTAssertEqual(sut.state, .done("요약 결과"))
    }

    // MARK: - 무관한 글 invalidate 격리

    /// 글 A 의 늦은 새로고침 완료가 B 로 전환된 뒤 invalidate(A) 를 부르면,
    /// A 캐시만 지워야지 B 의 세대/상태를 건드리면 안 된다.
    func testInvalidateForOtherPostKeepsCurrentState() async {
        let spy = GenerateSpy()
        let sut = summarizer(spy: spy)
        await sut.summarizeIfNeeded(postID: "A") { self.detail(postID: "A") }
        await sut.summarizeIfNeeded(postID: "B") { self.detail(postID: "B") }
        XCTAssertEqual(sut.state, .done("요약 결과"))
        XCTAssertEqual(spy.calls, 2)

        // B 가 현재 글인 상태에서 A 의 늦은 invalidate 도착.
        sut.invalidate(postID: "A")
        XCTAssertEqual(sut.state, .done("요약 결과"), "B 의 상태는 그대로")

        // B 재진입 → 캐시 복원(재생성 없음). A 재진입 → 캐시가 지워졌으니 재생성.
        await sut.summarizeIfNeeded(postID: "B") { self.detail(postID: "B") }
        XCTAssertEqual(spy.calls, 2, "B 캐시는 살아있다")
        await sut.summarizeIfNeeded(postID: "A") { self.detail(postID: "A") }
        XCTAssertEqual(spy.calls, 3, "A 캐시는 지워졌다")
    }

    // MARK: - 카드 마운트 게이트

    /// keep-alive 전환 중 로더는 이전 글의 detail 을 노출한다 — 그 스냅샷
    /// 으로 카드가 마운트되면, 새 글 로드가 느리거나 실패할 때 "요약 중…"
    /// 카드가 영구히 남는다. 카드는 로드된 detail 이 **현재 글**일 때만
    /// 마운트해야 한다.
    func testShouldShowRejectsStaleDetailFromPreviousPost() {
        let post = Post.fixture(id: "current")
        let staleLong = detail(
            postID: "previous",
            body: String(repeating: "가", count: PostSummaryPrompt.autoSummarizeMinChars)
        )
        XCTAssertFalse(PostSummarizer.shouldShowCard(post: post, loadedDetail: staleLong),
                       "이전 글 detail 로는 마운트하지 않는다")
        XCTAssertFalse(PostSummarizer.shouldShowCard(post: post, loadedDetail: nil))

        let currentLong = detail(
            postID: "current",
            body: String(repeating: "가", count: PostSummaryPrompt.autoSummarizeMinChars)
        )
        XCTAssertTrue(PostSummarizer.shouldShowCard(post: post, loadedDetail: currentLong))

        let currentShort = detail(postID: "current", body: "짧은 글")
        XCTAssertFalse(PostSummarizer.shouldShowCard(post: post, loadedDetail: currentShort),
                       "임계 미만은 현재 글이어도 비노출")
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
