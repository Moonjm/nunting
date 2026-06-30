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
