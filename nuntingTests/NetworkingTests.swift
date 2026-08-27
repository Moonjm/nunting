import XCTest
@testable import nunting

/// `URLProtocol`-stub-based tests for `Networking.fetchHTML`'s retry seam.
/// Production callers rely on the live `Networking.session` (which talks
/// to the network), but the function now takes an injectable `session:`
/// parameter so we can hand it a `URLSessionConfiguration.ephemeral`
/// session whose only registered protocol is `MockURLProtocol`. That
/// captures every attempted request and lets each test stage either a
/// canned response or a thrown error per attempt.
final class NetworkingTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    // MARK: - Happy path

    func testFetchHTMLReturnsBodyOnFirstAttemptSuccess() async throws {
        MockURLProtocol.handlers = [
            .response(status: 200, body: "<html>ok</html>"),
        ]

        let html = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(html, "<html>ok</html>")
        XCTAssertEqual(MockURLProtocol.attempts.count, 1)
    }

    // MARK: - Cache policy

    func testFetchHTMLThreadsCachePolicyToRequest() async throws {
        // 보드 목록은 항상 fresh 를 위해 reloadIgnoringLocalCacheData 를 넘긴다 —
        // 그게 실제 URLRequest 까지 도달하는지 핀.
        MockURLProtocol.handlers = [.response(status: 200, body: "<html>ok</html>")]

        _ = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            session: session
        )

        XCTAssertEqual(MockURLProtocol.attempts.first?.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testFetchHTMLDefaultsToProtocolCachePolicy() async throws {
        // 기본값은 세션 기본 정책 — cachePolicy 인자가 기존 호출부 동작을
        // 바꾸지 않음을 핀.
        MockURLProtocol.handlers = [.response(status: 200, body: "<html>ok</html>")]

        _ = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(MockURLProtocol.attempts.first?.cachePolicy, .useProtocolCachePolicy)
    }

    // MARK: - Transient retry

    func testFetchHTMLRetriesOnNetworkConnectionLostAndSucceeds() async throws {
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            .response(status: 200, body: "<html>retry-ok</html>"),
        ]

        let html = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(html, "<html>retry-ok</html>")
        XCTAssertEqual(MockURLProtocol.attempts.count, 2)
    }

    func testFetchHTMLRetriesOnTimedOutAndSucceeds() async throws {
        MockURLProtocol.handlers = [
            .failure(URLError(.timedOut)),
            .response(status: 200, body: "<html>retry-ok</html>"),
        ]

        let html = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(html, "<html>retry-ok</html>")
        XCTAssertEqual(MockURLProtocol.attempts.count, 2)
    }

    func testFetchHTMLRetriesOnCannotConnectToHostAndSucceeds() async throws {
        MockURLProtocol.handlers = [
            .failure(URLError(.cannotConnectToHost)),
            .response(status: 200, body: "<html>retry-ok</html>"),
        ]

        let html = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(html, "<html>retry-ok</html>")
        XCTAssertEqual(MockURLProtocol.attempts.count, 2)
    }

    func testFetchHTMLBothAttemptsTransientThrowsFinalError() async {
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
        ]

        do {
            _ = try await Networking.fetchHTML(
                url: URL(string: "https://example.com/")!,
                session: session
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
            XCTAssertEqual(MockURLProtocol.attempts.count, 2)
        }
    }

    // MARK: - Rate limit (429) retry

    /// 뽐뿌(`m.ppomppu.co.kr`)는 nginx `limit_req` 로 초당 ~2요청·버스트 ~10
    /// 을 넘기면 즉시 `429` 를 던진다(2026-08-27 실측: 동시 12요청에서 첫
    /// 거절, 회복은 2~4초). 앱은 목록 페이징·상세·댓글 페이지를 같은 호스트로
    /// 한꺼번에 쏘므로 정상 세션에서도 버킷이 마른다 — 429 를 영구 실패로
    /// 올리면 "하단 스크롤 → 다시 시도" / "특정 글만 안 열림"이 된다.
    /// 짧은 백오프 재시도로 흡수한다.
    func testFetchHTMLRetriesOn429AndSucceeds() async throws {
        MockURLProtocol.handlers = [
            .response(status: 429, body: "<html>429</html>"),
            .response(status: 200, body: "<html>after-429</html>"),
        ]

        let html = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            session: session,
            rateLimitBackoff: Self.fastBackoff
        )

        XCTAssertEqual(html, "<html>after-429</html>")
        XCTAssertEqual(MockURLProtocol.attempts.count, 2)
    }

    func testFetchHTMLRetries429TwiceBeforeGivingUp() async {
        // 백오프 스케줄 길이만큼만 재시도하고 마지막 429 를 그대로 던진다 —
        // 무한 재시도로 rate limit 을 더 태우지 않는다.
        MockURLProtocol.handlers = Array(
            repeating: .response(status: 429, body: "<html>429</html>"), count: 4)

        do {
            _ = try await Networking.fetchHTML(
                url: URL(string: "https://example.com/")!,
                session: session,
                rateLimitBackoff: Self.fastBackoff
            )
            XCTFail("expected failure")
        } catch let NetworkError.badResponse(code) {
            XCTAssertEqual(code, 429)
            XCTAssertEqual(MockURLProtocol.attempts.count, 3, "백오프 2회 = 시도 3회")
        } catch {
            XCTFail("expected NetworkError.badResponse, got \(error)")
        }
    }

    /// 429 재시도 예산과 transient 재시도 예산은 서로를 잡아먹지 않아야 한다.
    /// 공유 `attempt` 로 판정하던 판에서는 "429 → 연결 끊김" 순서일 때 두 번째
    /// 실패가 이미 예산을 다 쓴 것으로 읽혀 약속한 재다이얼이 사라졌다.
    func testTransientRetryStillAvailableAfter429() async throws {
        MockURLProtocol.handlers = [
            .response(status: 429, body: "<html>429</html>"),
            .failure(URLError(.networkConnectionLost)),
            .response(status: 200, body: "<html>ok</html>"),
        ]

        let html = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            session: session,
            rateLimitBackoff: Self.fastBackoff
        )

        XCTAssertEqual(html, "<html>ok</html>")
        XCTAssertEqual(MockURLProtocol.attempts.count, 3)
    }

    /// 백오프 스케줄은 실측 회복창(t=2s 아직 429, t=4s 200)을 **넘겨야** 한다.
    /// 마지막 시도가 회복 전에 떨어지면 재시도를 넣고도 같은 429 를 그대로
    /// 사용자에게 돌려준다 — 실기기에서 실제로 그랬다.
    func testProductionBackoffScheduleOutlastsMeasuredRecoveryWindow() {
        let total = Networking.rateLimitBackoff.reduce(Duration.zero, +)
        XCTAssertGreaterThanOrEqual(
            total, .seconds(4),
            "마지막 재시도가 실측 회복 시점(4s) 이후여야 함 — 현재 \(total)")
    }

    // MARK: - 시도 단위 계측

    func testRecordsOneOutcomePerAttemptWithStatuses() async throws {
        // 429 → 200 한 요청이 시도 2건으로 남아야 "재시도가 실제로 먹혔나"를
        // 사후에 판정할 수 있다. 요청 단위로만 남기면 흡수된 429 가 안 보인다.
        let spy = OutcomeSpy()
        MockURLProtocol.handlers = [
            .response(status: 429, body: "<html>429</html>"),
            .response(status: 200, body: "<html>ok</html>"),
        ]

        _ = try await Networking.fetchHTML(
            url: URL(string: "https://example.com/board")!,
            session: session,
            rateLimitBackoff: Self.fastBackoff,
            recorder: { spy.append($0) }
        )

        let outcomes = spy.outcomes
        XCTAssertEqual(outcomes.map(\.status), [429, 200])
        XCTAssertEqual(outcomes.map(\.attempt), [1, 2])
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
    }

    func testRecordsTransportFailureOnceWithoutStatus() async {
        // 응답이 없는 실패(타임아웃 등)는 status 없이 err 로 남아야 하고,
        // 같은 시도가 두 번 실리면 안 된다(위 do 블록과 catch 의 이중 기록).
        let spy = OutcomeSpy()
        MockURLProtocol.handlers = [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
        ]

        _ = try? await Networking.fetchHTML(
            url: URL(string: "https://example.com/board")!,
            session: session,
            rateLimitBackoff: Self.fastBackoff,
            recorder: { spy.append($0) }
        )

        let outcomes = spy.outcomes
        XCTAssertEqual(outcomes.count, 2, "시도 2회 = 이벤트 2건")
        XCTAssertTrue(outcomes.allSatisfy { $0.status == nil })
        XCTAssertEqual(
            outcomes.compactMap { ($0.error as? URLError)?.code }, [.timedOut, .timedOut])
    }

    func testHTTPErrorStatusIsRecordedOnlyOnce() async {
        // 500 은 do 블록이 기록하고 던진다 — catch 가 다시 실으면 상태 분포가
        // 두 배가 된다.
        let spy = OutcomeSpy()
        MockURLProtocol.handlers = [.response(status: 500, body: "<html>boom</html>")]

        _ = try? await Networking.fetchHTML(
            url: URL(string: "https://example.com/board")!,
            session: session,
            recorder: { spy.append($0) }
        )

        XCTAssertEqual(spy.outcomes.map(\.status), [500])
    }

    // MARK: - 요청률 게이트

    func testRateLimitedHostPassesThroughPacer() async throws {
        // 게이트가 fetch 경로에 실제로 물려 있는지 — 뽐뿌 호스트로 capacity(6)를
        // 넘겨 쏘면 대기가 발생해야 한다. 배선이 빠지면 계측만 남고 429 는
        // 그대로 난다.
        let gate = PacerSpy()
        let pacer = HostRequestPacer(clock: { gate.now }, sleeper: { gate.sleep($0) })
        MockURLProtocol.handlers = Array(
            repeating: .response(status: 200, body: "<html>ok</html>"), count: 8)

        for _ in 0..<8 {
            _ = try await Networking.fetchHTML(
                url: URL(string: "https://m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu")!,
                session: session,
                pacer: pacer)
        }

        XCTAssertEqual(gate.waits.count, 2, "6건은 즉시, 나머지는 대기")
    }

    func testUnknownHostIsNotPaced() async throws {
        // 제한이 관측되지 않은 호스트까지 늦추면 순전한 손해다.
        let gate = PacerSpy()
        let pacer = HostRequestPacer(clock: { gate.now }, sleeper: { gate.sleep($0) })
        MockURLProtocol.handlers = Array(
            repeating: .response(status: 200, body: "<html>ok</html>"), count: 8)

        for _ in 0..<8 {
            _ = try await Networking.fetchHTML(
                url: URL(string: "https://example.com/")!,
                session: session,
                pacer: pacer)
        }

        XCTAssertTrue(gate.waits.isEmpty)
    }

    func testRetriesAlsoPassThroughPacer() async throws {
        // 429 재시도야말로 남은 토큰을 태우는 주범이었다 — 재시도가 게이트를
        // 우회하면 증폭 고리가 그대로 남는다.
        let gate = PacerSpy()
        let pacer = HostRequestPacer(clock: { gate.now }, sleeper: { gate.sleep($0) })
        // 1회 요청이 시도 7회(=capacity 6 초과)를 쓰도록 429 를 6번 준다.
        MockURLProtocol.handlers = Array(
            repeating: .response(status: 429, body: "<html>429</html>"), count: 6)
            + [.response(status: 200, body: "<html>ok</html>")]

        _ = try await Networking.fetchHTML(
            url: URL(string: "https://m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu")!,
            session: session,
            rateLimitBackoff: Array(repeating: .milliseconds(1), count: 6),
            pacer: pacer)

        XCTAssertEqual(gate.waits.count, 1, "7번째 시도는 게이트에서 대기해야 함")
    }

    /// 짧은 백오프 스케줄 — 프로덕션 값을 그대로 쓰면 테스트가 초 단위로 잔다.
    /// 재시도 **횟수**와 종료 조건만 검증 대상이라 길이는 무관(스케줄 길이
    /// 자체는 `testProductionBackoffScheduleOutlastsMeasuredRecoveryWindow` 가 핀).
    private static let fastBackoff: [Duration] = [.milliseconds(1), .milliseconds(1)]

    // MARK: - Non-retry paths

    func testFetchHTMLDoesNotRetryOnHTTPErrorResponse() async {
        MockURLProtocol.handlers = [
            .response(status: 500, body: "<html>boom</html>"),
        ]

        do {
            _ = try await Networking.fetchHTML(
                url: URL(string: "https://example.com/")!,
                session: session
            )
            XCTFail("expected failure")
        } catch let NetworkError.badResponse(code) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(MockURLProtocol.attempts.count, 1)
        } catch {
            XCTFail("expected NetworkError.badResponse, got \(error)")
        }
    }

    func testFetchHTMLDoesNotRetryOnCancelled() async {
        // URLError.cancelled (-999) is the URLSession-side cancel; it is
        // intentionally NOT in the transient set. A cancelled request
        // should propagate immediately without a retry attempt.
        MockURLProtocol.handlers = [
            .failure(URLError(.cancelled)),
        ]

        do {
            _ = try await Networking.fetchHTML(
                url: URL(string: "https://example.com/")!,
                session: session
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
            XCTAssertEqual(MockURLProtocol.attempts.count, 1)
        }
    }

    func testFetchHTMLDoesNotRetryOnDNSFailure() async {
        // Sanity counterpart — non-transient URL errors (here `cannotFindHost`,
        // a permanent DNS failure) shouldn't retry. Failing one in the
        // transient direction would silently double network traffic for
        // every dead-host call site.
        MockURLProtocol.handlers = [
            .failure(URLError(.cannotFindHost)),
        ]

        do {
            _ = try await Networking.fetchHTML(
                url: URL(string: "https://example.com/")!,
                session: session
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotFindHost)
            XCTAssertEqual(MockURLProtocol.attempts.count, 1)
        }
    }

    // MARK: - Cancellation

    func testFetchHTMLDoesNotRetryAfterCancellationDuringBackoff() async {
        // Pin the cancellation seam in `fetchHTML`'s retry loop:
        // `try? await Task.sleep(...)` swallows CancellationError, so
        // the only thing preventing a wasted second round-trip when the
        // task is cancelled mid-backoff is the explicit
        // `try Task.checkCancellation()` after the sleep. If a future
        // refactor removes that line, this test catches the regression
        // (attempts.count becomes 2).
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            // No second handler staged — if the retry mistakenly fires,
            // MockURLProtocol's empty-queue fallback throws
            // URLError.unknown, but we'd still see attempts == 2.
        ]

        // 로컬 바인딩: 인스턴스 프로퍼티(session) 캡처는 non-Sendable self
        // 캡처가 돼 Swift 6 sending 검사에 걸린다. URLSession 은 Sendable.
        let session: URLSession = self.session
        let task = Task {
            try await Networking.fetchHTML(
                url: URL(string: "https://example.com/")!,
                session: session
            )
        }

        // Wait long enough for the first attempt to dispatch and enter
        // the 150 ms backoff sleep, but well short of the sleep's end.
        try? await Task.sleep(for: .milliseconds(75))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected error after cancellation")
        } catch {
            // Acceptable outcomes — order depends on whether the cancel
            // raced ahead of the first attempt's failure or landed
            // squarely in the backoff sleep:
            //   * `CancellationError` from `try Task.checkCancellation()`
            //   * original `URLError.networkConnectionLost` if
            //     cancellation arrived after the catch made its retry
            //     decision but before re-entering the loop
            //   * `URLError.cancelled` if URLSession.data(for:) saw
            //     cancellation in-flight on the first attempt
            let acceptable = error is CancellationError
                || (error as? URLError)?.code == .networkConnectionLost
                || (error as? URLError)?.code == .cancelled
            XCTAssertTrue(acceptable, "unexpected error type: \(error)")
        }

        XCTAssertLessThanOrEqual(
            MockURLProtocol.attempts.count, 1,
            "cancellation during backoff must not trigger a retry attempt"
        )
    }

    // MARK: - Per-attempt timeout

    func testFetchHTMLAppliesShorterTimeoutOnFirstAttemptOnly() async {
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
        ]

        _ = try? await Networking.fetchHTML(
            url: URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(MockURLProtocol.attempts.count, 2)
        let first = MockURLProtocol.attempts[0].timeoutInterval
        let second = MockURLProtocol.attempts[1].timeoutInterval
        XCTAssertEqual(first, 8, accuracy: 0.001,
                       "first attempt should use the fast-fail idle timeout")
        // Layered timeout note: the URLRequest's natural default is 60 s
        // (Apple's documented default), and `fetchHTML` deliberately
        // skips the per-request override on retry. The effective timeout
        // at the URLSession layer is then min(60, session config 15) =
        // 15 s — but the URLRequest object itself reads 60. This
        // assertion pins the "no per-request override on retry"
        // invariant; do NOT "fix" the 60 to 15, that would hardcode a
        // value that should track the session config.
        XCTAssertEqual(second, 60, accuracy: 0.001,
                       "retry must NOT carry the first attempt's per-request override")
    }

    // MARK: - resolveFinalURL retry

    /// HEAD failing transient on attempt 1 must retry on the same leg before
    /// falling back to GET — symmetric with `fetchHTML`'s policy. Without this,
    /// the aagag → SLR mirror redirect step silently drops to GET on a single
    /// stale-keepalive bounce, and a wedged pool can take down both legs.
    func testResolveFinalURLHEADRetriesOnTransientThenFallsToGET() async {
        // HEAD #1 fails transient, HEAD #2 succeeds with same URL (no redirect),
        // so the resolver moves on to GET as the prefetched-body capture path.
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            .response(status: 200, body: ""),
            .response(status: 200, body: "<html>got</html>"),
        ]

        let result = await Networking.resolveFinalURL(
            URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(MockURLProtocol.attempts.count, 3)
        XCTAssertEqual(result.prefetchedBody.flatMap { String(data: $0, encoding: .utf8) },
                       "<html>got</html>")
    }

    /// GET fallback must also honor the retry policy. Pin this so a future
    /// refactor that adds retry to HEAD only can't silently regress the GET
    /// path — the wedged-pool failure mode the retry exists for is identical
    /// on either method.
    func testResolveFinalURLGETRetriesOnTransient() async {
        MockURLProtocol.handlers = [
            // HEAD exhausts retry transient → fall to GET.
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
            // GET #1 transient, GET #2 succeeds.
            .failure(URLError(.networkConnectionLost)),
            .response(status: 200, body: "<html>g</html>"),
        ]

        let result = await Networking.resolveFinalURL(
            URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(MockURLProtocol.attempts.count, 4)
        XCTAssertEqual(result.prefetchedBody.flatMap { String(data: $0, encoding: .utf8) },
                       "<html>g</html>")
    }

    /// Total failure (both legs exhausted) must surface the original URL with
    /// no body — callers (`PostDetailLoader.resolveDispatchedPost`) treat that
    /// as "no redirect happened" and stay on the original parser. Returning a
    /// stale or made-up URL here would silently route the wrong parser.
    func testResolveFinalURLAllFailReturnsOriginalURL() async {
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
        ]

        let url = URL(string: "https://example.com/")!
        let result = await Networking.resolveFinalURL(url, session: session)

        XCTAssertEqual(MockURLProtocol.attempts.count, 4)
        XCTAssertEqual(result.url, url)
        XCTAssertNil(result.prefetchedBody)
    }

    /// Non-transient errors (DNS, cancelled) must NOT trigger a retry on either
    /// leg — same invariant as `fetchHTML`. A future widening of
    /// `transientURLErrorCodes` that drags in `cannotFindHost` would silently
    /// double network traffic for every dead-host call site.
    func testResolveFinalURLDoesNotRetryNonTransient() async {
        MockURLProtocol.handlers = [
            .failure(URLError(.cannotFindHost)),  // HEAD: no retry
            .failure(URLError(.cannotFindHost)),  // GET fallback: no retry
        ]

        let url = URL(string: "https://example.com/")!
        let result = await Networking.resolveFinalURL(url, session: session)

        XCTAssertEqual(MockURLProtocol.attempts.count, 2)
        XCTAssertEqual(result.url, url)
        XCTAssertNil(result.prefetchedBody)
    }

    /// Pin per-attempt timeout shape so the fast-fail-then-fresh-dial pattern
    /// stays in place. First attempt of each leg uses
    /// `firstAttemptIdleTimeout` (8 s); the retry strips the per-request
    /// override and falls back to URLRequest's natural default (60 s, capped
    /// at the session layer by `timeoutIntervalForRequest = 15`).
    func testResolveFinalURLAppliesShorterTimeoutOnFirstAttemptPerLeg() async {
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
        ]

        _ = await Networking.resolveFinalURL(
            URL(string: "https://example.com/")!,
            session: session
        )

        XCTAssertEqual(MockURLProtocol.attempts.count, 4)
        // HEAD leg
        XCTAssertEqual(MockURLProtocol.attempts[0].timeoutInterval, 8, accuracy: 0.001)
        XCTAssertEqual(MockURLProtocol.attempts[1].timeoutInterval, 10, accuracy: 0.001)
        // GET leg
        XCTAssertEqual(MockURLProtocol.attempts[2].timeoutInterval, 8, accuracy: 0.001)
        XCTAssertEqual(MockURLProtocol.attempts[3].timeoutInterval, 10, accuracy: 0.001)
    }

    // MARK: - postForm retry

    /// Symmetric with the fetchHTML happy-path test: one good response, one
    /// captured request. Pins the no-retry-on-success invariant so a future
    /// refactor that re-runs the loop unconditionally can't double-fire a
    /// comment POST.
    func testPostFormReturnsBodyOnFirstAttemptSuccess() async throws {
        MockURLProtocol.handlers = [
            .response(status: 200, body: "{\"c\":[]}"),
        ]

        let data = try await Networking.postForm(
            url: URL(string: "https://example.com/comment_db/load.php")!,
            parameters: ["id": "free"],
            session: session
        )

        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"c\":[]}")
        XCTAssertEqual(MockURLProtocol.attempts.count, 1)
    }

    /// The actual user-facing failure that motivated this retry: SLR comment
    /// POST hits a stale keep-alive connection (-1005) and `PostDetailLoader`'s
    /// `try?` swallows the throw, leaving the user with body but no comments.
    /// Without this retry, that single bounce permanently strips comments
    /// from the post.
    func testPostFormRetriesOnNetworkConnectionLostAndSucceeds() async throws {
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            .response(status: 200, body: "{\"c\":[{\"pk\":\"x\"}]}"),
        ]

        let data = try await Networking.postForm(
            url: URL(string: "https://example.com/comment_db/load.php")!,
            parameters: [:],
            session: session
        )

        XCTAssertEqual(String(data: data, encoding: .utf8), "{\"c\":[{\"pk\":\"x\"}]}")
        XCTAssertEqual(MockURLProtocol.attempts.count, 2)
    }

    /// Retry exhaustion must surface the original URLError (not silently
    /// succeed with empty data), so callers / SwiftUI views can distinguish
    /// a real outage from "no comments yet". Pin all three transient codes
    /// since they share the same wedged-pool root cause.
    func testPostFormBothAttemptsTransientThrowsFinalError() async {
        MockURLProtocol.handlers = [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
        ]

        do {
            _ = try await Networking.postForm(
                url: URL(string: "https://example.com/")!,
                parameters: [:],
                session: session
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
            XCTAssertEqual(MockURLProtocol.attempts.count, 2)
        }
    }

    /// HTTP error response is non-retryable — bumping a 500 again would just
    /// double the load on a server that's already struggling. Same invariant
    /// fetchHTML pins; symmetry is the goal.
    func testPostFormDoesNotRetryOnHTTPErrorResponse() async {
        MockURLProtocol.handlers = [
            .response(status: 500, body: "boom"),
        ]

        do {
            _ = try await Networking.postForm(
                url: URL(string: "https://example.com/")!,
                parameters: [:],
                session: session
            )
            XCTFail("expected failure")
        } catch let NetworkError.badResponse(code) {
            XCTAssertEqual(code, 500)
            XCTAssertEqual(MockURLProtocol.attempts.count, 1)
        } catch {
            XCTFail("expected NetworkError.badResponse, got \(error)")
        }
    }

    /// Same per-attempt timeout shape as fetchHTML: first attempt 8 s, retry
    /// strips the override and inherits the URLRequest natural default
    /// (60 s, capped at session-config 15 s on the live session). Pin both
    /// values so a future refactor that hardcodes 15 here decouples from the
    /// session config.
    func testPostFormAppliesShorterTimeoutOnFirstAttemptOnly() async {
        MockURLProtocol.handlers = [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.networkConnectionLost)),
        ]

        _ = try? await Networking.postForm(
            url: URL(string: "https://example.com/")!,
            parameters: [:],
            session: session
        )

        XCTAssertEqual(MockURLProtocol.attempts.count, 2)
        XCTAssertEqual(MockURLProtocol.attempts[0].timeoutInterval, 8, accuracy: 0.001)
        XCTAssertEqual(MockURLProtocol.attempts[1].timeoutInterval, 60, accuracy: 0.001)
    }
}

// MARK: - URLProtocol mock

/// Records every captured request and returns staged responses / errors
/// in order. One handler entry is consumed per `startLoading()` call;
/// running out of handlers fails the test deterministically (vs. silently
/// returning an unstubbed error and producing confusing failure modes).
final class MockURLProtocol: URLProtocol {
    enum Handler {
        case response(status: Int, body: String, headers: [String: String] = [:])
        case failure(Error)
    }

    /// Serial queue guarding the static state below. `startLoading()`
    /// runs on a URLSession-internal queue while tests read
    /// `attempts` / write `handlers` from the test thread — without
    /// synchronization this is a write-on-thread-A / read-on-thread-B
    /// race that XCTest's currently-serial scheduling masks. Routing
    /// every access through this queue restores the Swift-6 strict-
    /// concurrency guarantee the rest of the codebase honors via
    /// `actor` types.
    private static let queue = DispatchQueue(label: "MockURLProtocol.state")
    nonisolated(unsafe) private static var _handlers: [Handler] = []
    nonisolated(unsafe) private static var _attempts: [URLRequest] = []

    static var handlers: [Handler] {
        get { queue.sync { _handlers } }
        set { queue.sync { _handlers = newValue } }
    }

    static var attempts: [URLRequest] {
        queue.sync { _attempts }
    }

    static func reset() {
        queue.sync {
            _handlers = []
            _attempts = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Single critical section per call: append the captured request
        // and pop the next handler atomically. Otherwise an interleaved
        // reader could observe `attempts` having grown without the
        // corresponding handler having been consumed yet.
        let handler: Handler? = Self.queue.sync {
            Self._attempts.append(self.request)
            return Self._handlers.isEmpty ? nil : Self._handlers.removeFirst()
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        switch handler {
        case .response(let status, let body, let headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.unknown))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// All response/failure events are dispatched synchronously inside
    /// `startLoading()`, so by the time `stopLoading` is called there
    /// is no async work left to cancel. If a future handler dispatches
    /// its response asynchronously (e.g. simulated slow network), this
    /// will need to cancel that timer.
    override func stopLoading() {}
}

/// `recorder` 시임이 받은 결과를 모으는 스파이. `@Sendable` 클로저에서 갱신되므로
/// 락으로 감싼다 — 클래스 필드에 그냥 쓰면 Swift 6 sending 검사에 걸린다.
private final class OutcomeSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [FetchAttemptOutcome] = []

    func append(_ outcome: FetchAttemptOutcome) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(outcome)
    }

    var outcomes: [FetchAttemptOutcome] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 페이서의 가짜 시계 — 요청된 대기만큼 시계를 돌려 실제로 자지 않는다.
private final class PacerSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 1_000
    private var recorded: [Double] = []

    var now: Double {
        lock.lock(); defer { lock.unlock() }
        return seconds
    }

    func sleep(_ duration: Double) {
        lock.lock(); defer { lock.unlock() }
        recorded.append(duration)
        seconds += duration
    }

    var waits: [Double] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}
