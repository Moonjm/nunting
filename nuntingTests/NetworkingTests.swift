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
        XCTAssertGreaterThan(second, first,
                             "retry should fall back to the session default (no per-request override)")
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

    nonisolated(unsafe) static var handlers: [Handler] = []
    nonisolated(unsafe) static var attempts: [URLRequest] = []

    static func reset() {
        handlers = []
        attempts = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.attempts.append(request)
        guard !Self.handlers.isEmpty else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let handler = Self.handlers.removeFirst()
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

    override func stopLoading() {}
}
