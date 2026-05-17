import Foundation
/// Single-writer gate for `Networking.prewarmConnections`. Callers
/// request `claimRun()`; the actor returns `true` only if enough time
/// has passed since the last successful claim, which throttles scene-
/// phase bounce-induced redundant HEAD bursts. An `actor` (not
/// `@MainActor`) so the gate read/write stays off the main thread.
actor PrewarmThrottle {
    static let shared = PrewarmThrottle()
    /// Any request within this interval of the last run is dropped.
    /// Chosen to be well under the URLSession keep-alive window
    /// (~60 s) so the pool is reliably warm between successful runs.
    private let interval: TimeInterval = 30
    private var lastRun: Date?

    func claimRun(now: Date = Date()) -> Bool {
        if let lastRun, now.timeIntervalSince(lastRun) < interval {
            return false
        }
        lastRun = now
        return true
    }
}

extension URL {
    /// Returns `https://<host>/<path>` when `self` is plain `http://`,
    /// otherwise returns `self` unchanged. Lets ATS-clean hosts load
    /// media (`<img>` / zoom viewer) without a global `NSAllowsArbitraryLoads`
    /// exception. Most of the image CDNs embedded in community-board posts
    /// (carisyou, tistory, etc.) serve the same path over HTTPS, so a
    /// blind upgrade is safe; callers that need the original scheme
    /// should not use this helper.
    var atsSafe: URL {
        guard scheme?.lowercased() == "http",
              var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)
        else { return self }
        comps.scheme = "https"
        return comps.url ?? self
    }
}

enum NetworkError: Error, LocalizedError {
    case badResponse(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "HTTP \(code)"
        case .decodingFailed: "응답 디코딩 실패"
        }
    }
}

struct Networking {
    nonisolated static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// Desktop UA for endpoints that serve a JS-redirect to mobile when given
    /// a mobile UA (e.g. ppomppu's `www.` host).
    nonisolated static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // `nonisolated` so the `session` initializer below — also nonisolated —
    // can reference this without crossing isolation boundaries. Default
    // isolation under Swift 6 would otherwise infer MainActor for a plain
    // `static let` on a non-actor type and break the default-argument
    // references on `fetchHTML` / `resolveFinalURL` / `postForm`.
    nonisolated static let sharedCache: URLCache = {
        let cache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            directory: nil
        )
        URLCache.shared = cache
        return cache
    }()

    /// Rewrites `http://` redirect targets to `https://` before URLSession
    /// follows them. Some upstream sites (observed on Clien when the guest
    /// session cookie is stale) issue a 30x with an `http://` Location, which
    /// App Transport Security then blocks and surfaces as "The resource could
    /// not be loaded because the App Transport Security policy requires the
    /// use of a secure connection." All boards we scrape serve HTTPS on the
    /// same host, so a blind upgrade is safe and avoids an ATS exception.
    private final class RedirectHTTPSUpgrader: NSObject, URLSessionTaskDelegate {
        // `session.data(for:)` (the async API) invokes this task-level
        // delegate method on the session's delegate when the session was
        // constructed with one — documented behaviour since iOS 15. Do not
        // "fix" this by migrating to per-task `URLSessionTaskDelegate`
        // arguments; we need the single shared upgrader to cover every
        // caller (`fetchHTML`, `postForm`, `resolveFinalURL`) without
        // touching each one.
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url,
                  url.scheme?.lowercased() == "http",
                  var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else {
                completionHandler(request)
                return
            }
            comps.scheme = "https"
            guard let upgraded = comps.url else {
                completionHandler(request)
                return
            }
            var upgradedRequest = request
            upgradedRequest.url = upgraded
            completionHandler(upgradedRequest)
        }
    }

    // Stateless delegate (no stored mutable properties); `nonisolated` so it
    // doesn't pull the `session` initializer below into MainActor inference.
    nonisolated private static let redirectUpgrader = RedirectHTTPSUpgrader()

    // `nonisolated` so the default-argument references on `fetchHTML` /
    // `resolveFinalURL` / `postForm` can read this from a nonisolated context
    // under Swift 6 default-isolation. URLSession is documented thread-safe.
    nonisolated static let session: URLSession = {
        _ = sharedCache
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 15
        config.urlCache = sharedCache
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config, delegate: redirectUpgrader, delegateQueue: nil)
    }()

    /// URLSession transient errors retried by `fetchHTML` (and image
    /// fetches in `ImageDataLoader`). Same root cause as the image-side
    /// retry: the iOS pool occasionally hands out a stale keep-alive
    /// connection whose remote half the server has already closed —
    /// the first write hits a TCP RST and surfaces as -1005 in
    /// ~280 ms, or as -1001 / -1004 when the connect leg itself fails.
    /// Observed on `m.slrclub.com` HTML body fetches where one in N
    /// detail opens used to fail with "본문이 안 나옴". A single retry
    /// after a short backoff dials a fresh connection and clears it
    /// in practice. See radar #21663589.
    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .networkConnectionLost,    // -1005
        .timedOut,                 // -1001
        .cannotConnectToHost,      // -1004
    ]

    /// Per-request idle timeout applied to the FIRST attempt only. Session
    /// default (`timeoutIntervalForRequest = 15`) still backs the retry
    /// attempt. Rationale: -1001 (timed out) on the first attempt almost
    /// always means the keep-alive connection is dead, not that the host
    /// is genuinely slow — fail it faster so the retry's fresh-dial path
    /// kicks in earlier. iOS's `timeoutInterval` is an *idle* timeout
    /// (resets on every byte received), so 8 s of zero data flow is well
    /// past the threshold for "live but slow" and squarely in
    /// "connection is wedged" territory. Worst-case fetchHTML latency
    /// drops from ~30 s (15+15) to ~23 s (8+15).
    private static let firstAttemptIdleTimeout: TimeInterval = 8

    static func fetchHTML(
        url: URL,
        encoding: String.Encoding = .utf8,
        userAgent: String? = nil,
        handlesCookies: Bool = true,
        session: URLSession = Networking.session
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = handlesCookies
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")

        let maxAttempts = 2
        var attempt = 0
        while true {
            attempt += 1
            var attemptRequest = request
            if attempt == 1 {
                attemptRequest.timeoutInterval = firstAttemptIdleTimeout
            }
            do {
                let (data, response) = try await session.data(for: attemptRequest)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw NetworkError.badResponse(http.statusCode)
                }
                return decodeHTML(data: data, encoding: encoding)
            } catch {
                let isTransient = (error as? URLError)
                    .map { Self.transientURLErrorCodes.contains($0.code) }
                    ?? false
                if isTransient && attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(150))
                    try Task.checkCancellation()
                    continue
                }
                throw error
            }
        }
    }

    /// Strict-then-lossy decode shared with the redirect-resolver path that
    /// reuses an already-fetched body to avoid a second round-trip.
    static func decodeHTML(data: Data, encoding: String.Encoding) -> String {
        if let html = String(data: data, encoding: encoding) {
            return html
        }
        if encoding == .utf8 {
            return String(decoding: data, as: UTF8.self)
        }
        // Legacy-encoding lossy fallback: walk bytes and replace any sequence the
        // strict decoder rejected with U+FFFD so the user sees a partial page
        // instead of a hard failure (e.g. truncated CP949 multi-byte at EOF).
        return lossyDecode(data: data, encoding: encoding)
    }

    private static func lossyDecode(data: Data, encoding: String.Encoding) -> String {
        // Try chunks separated by ASCII boundaries; replace failed chunks with U+FFFD.
        var output = ""
        var idx = data.startIndex
        var pending = Data()

        func flush(_ buf: inout Data) {
            guard !buf.isEmpty else { return }
            if let s = String(data: buf, encoding: encoding) {
                output.append(s)
            } else {
                output.append("\u{FFFD}")
            }
            buf.removeAll(keepingCapacity: true)
        }

        while idx < data.endIndex {
            let byte = data[idx]
            if byte < 0x80 {
                // ASCII boundary — flush accumulated multibyte run, then append ASCII directly.
                flush(&pending)
                output.append(Character(UnicodeScalar(byte)))
            } else {
                pending.append(byte)
            }
            idx = data.index(after: idx)
        }
        flush(&pending)
        return output
    }

    struct ResolvedRedirect {
        let url: URL
        /// When non-nil, the body fetched while discovering the URL — return it
        /// to the caller so they don't have to re-fetch the same URL.
        let prefetchedBody: Data?
    }

    /// Resolve a URL by following redirects with HEAD (cheap) and falling back
    /// to GET (which captures the body so it can be reused). Returns the
    /// original URL with no body on total failure.
    ///
    /// Both legs apply the same transient-retry policy as `fetchHTML`: a single
    /// retry on -1005 / -1001 / -1004 after a 150 ms backoff, with the first
    /// attempt using `firstAttemptIdleTimeout` so a wedged keep-alive
    /// connection fails fast and the retry's fresh dial path kicks in. Without
    /// this, the aagag → SLR / Ddanzi / etc. mirror redirect leg used to
    /// silently fall through both HEAD and GET on a single bad pool entry,
    /// surface the original aagag URL, and end with `AagagParser` running on
    /// the source site's body — which the user sees as "불러오기 실패".
    static func resolveFinalURL(
        _ url: URL,
        session: URLSession = Networking.session
    ) async -> ResolvedRedirect {
        if let result = await resolveAttempt(
            url: url, method: "HEAD", captureBody: false, session: session
        ), result.url != url {
            return ResolvedRedirect(url: result.url, prefetchedBody: nil)
        }
        // Some endpoints reject HEAD or return 200 without redirecting; fall
        // back to GET. We capture `data` so callers can decode it directly
        // instead of re-fetching the same URL.
        if let result = await resolveAttempt(
            url: url, method: "GET", captureBody: true, session: session
        ) {
            return ResolvedRedirect(url: result.url, prefetchedBody: result.body)
        }
        return ResolvedRedirect(url: url, prefetchedBody: nil)
    }

    /// Single HEAD-or-GET pass with the same retry policy as `fetchHTML`. Returns
    /// `nil` on permanent failure (HTTP error, non-transient URLError, retry
    /// exhausted, etc.); callers that need the HEAD→GET fallback own the
    /// branch logic themselves.
    private static func resolveAttempt(
        url: URL,
        method: String,
        captureBody: Bool,
        session: URLSession
    ) async -> (url: URL, body: Data?)? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Tighter than `fetchHTML` / `postForm` (which inherit URLRequest's
        // 60 s default capped at the session config's 15 s) because the
        // resolver is a probe — a redirect target should arrive in well
        // under 10 s on any host we list, and dragging this out only delays
        // the GET fallback / detail dispatch downstream.
        request.timeoutInterval = 10

        let maxAttempts = 2
        var attempt = 0
        while true {
            attempt += 1
            var attemptRequest = request
            if attempt == 1 {
                attemptRequest.timeoutInterval = firstAttemptIdleTimeout
            }
            do {
                let (data, response) = try await session.data(for: attemptRequest)
                guard let final = response.url else { return nil }
                return (final, captureBody ? data : nil)
            } catch {
                let isTransient = (error as? URLError)
                    .map { Self.transientURLErrorCodes.contains($0.code) }
                    ?? false
                if isTransient && attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(150))
                    // Cancellation is intentionally swallowed here (returned
                    // as `nil`) rather than thrown — `resolveFinalURL`'s
                    // signature is non-throwing. Callers MUST run a
                    // `try Task.checkCancellation()` immediately after
                    // `resolveFinalURL` so a cancelled task can't proceed
                    // into a wasted parser dispatch. `PostDetailLoader.load`
                    // already does this on the line after `resolveDispatchedPost`.
                    if Task.isCancelled { return nil }
                    continue
                }
                return nil
            }
        }
    }

    /// Fire a best-effort `HEAD /` to every supported-site host so the
    /// shared `URLSession` opens a TLS + HTTP/2 connection pool entry
    /// per host. Subsequent real requests (list / detail fetches) reuse
    /// the pooled connection and skip the 300-700 ms TLS handshake that
    /// the perf log showed on the first access per host per session.
    ///
    /// All requests run in parallel on a detached `.utility` task, have
    /// a short 5-second timeout, ignore errors, and do *not* persist
    /// cookies — the goal is TLS pool population, not populating the
    /// shared `HTTPCookieStorage` with session trackers before the user
    /// has navigated anywhere. Worst case on failure is the same cold
    /// handshake the app used to pay, not a regression.
    ///
    /// Throttled via `PrewarmThrottle` to skip re-warming on rapid
    /// scenePhase bounces (notification peek, Control Center pull-down,
    /// quick foreground→background→foreground cycles). The pool stays
    /// warm for ~60 s of idle anyway, so re-warming more often than
    /// once every 30 s is pure noise.
    nonisolated static func prewarmConnections(hosts: [URL] = Site.allCases.map(\.baseURL)) {
        // Dedup as a defensive step — all 10 current `Site` cases have
        // distinct base hosts, but a future case sharing a host (or an
        // override caller passing duplicates) shouldn't fire the same
        // HEAD twice.
        let uniqueHosts = Set(hosts)
        Task.detached(priority: .utility) {
            guard await PrewarmThrottle.shared.claimRun() else { return }
            await withTaskGroup(of: Void.self) { group in
                for host in uniqueHosts {
                    group.addTask {
                        var request = URLRequest(url: host)
                        request.httpMethod = "HEAD"
                        request.timeoutInterval = 5
                        request.httpShouldHandleCookies = false
                        _ = try? await session.data(for: request)
                    }
                }
            }
        }
    }

    /// Same transient-retry policy as `fetchHTML`. Every current caller is a
    /// read-only POST endpoint (SLR / Ddanzi / Inven / Aagag comment loaders
    /// implemented as POST-as-GET), so a retry on -1005 / -1001 / -1004 cannot
    /// cause a double-submit. Without this, a single wedged keep-alive
    /// connection on the comment-host pool used to silently swallow the
    /// comment list — `PostDetailLoader` `try?`-wraps `fetchAllComments`,
    /// turning a transient network blip into "본문은 보이는데 댓글이 안 뜸".
    static func postForm(
        url: URL,
        parameters: [String: String],
        referer: URL? = nil,
        /// Override the outgoing `Content-Type` header for endpoints that
        /// expect a value not matching the URL-encoded body shape. The
        /// default is correct for normal form POSTs; only override when a
        /// server specifically branches on this header. See `DdanziParser`
        /// for the current caller that needs this.
        contentType: String = "application/x-www-form-urlencoded; charset=utf-8",
        session: URLSession = Networking.session
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if let scheme = referer.scheme, let host = referer.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }

        var comps = URLComponents()
        comps.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let maxAttempts = 2
        var attempt = 0
        while true {
            attempt += 1
            var attemptRequest = request
            if attempt == 1 {
                attemptRequest.timeoutInterval = firstAttemptIdleTimeout
            }
            do {
                let (data, response) = try await session.data(for: attemptRequest)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    #if DEBUG
                    let preview = String(data: data.prefix(256), encoding: .utf8) ?? "<binary>"
                    print("[Networking.postForm] HTTP \(http.statusCode) for \(url.absoluteString): \(preview)")
                    #endif
                    throw NetworkError.badResponse(http.statusCode)
                }
                return data
            } catch {
                let isTransient = (error as? URLError)
                    .map { Self.transientURLErrorCodes.contains($0.code) }
                    ?? false
                if isTransient && attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(150))
                    try Task.checkCancellation()
                    continue
                }
                throw error
            }
        }
    }
}
