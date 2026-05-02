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
