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

enum NetworkError: Error, LocalizedError {
    case badResponse(Int)
    case decodingFailed
    /// Site served a CAPTCHA / bot-check interstitial twice in a row
    /// (once on the original fetch, once after the user-driven recovery
    /// via `BotCheckCoordinator`). Surfaced as a normal error so the
    /// loader's existing catch path renders a message instead of
    /// looping the sheet.
    case captchaChallenge(URL)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "HTTP \(code)"
        case .decodingFailed: "응답 디코딩 실패"
        case .captchaChallenge: "자동등록방지 통과 실패 — 다시 시도해 주세요"
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
    static let transientURLErrorCodes: Set<URLError.Code> = [
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
    static let firstAttemptIdleTimeout: TimeInterval = 8

    static func fetchHTML(
        url: URL,
        encoding: String.Encoding = .utf8,
        userAgent: String? = nil,
        handlesCookies: Bool = true,
        session: URLSession = Networking.session
    ) async throws -> String {
        let retry: @Sendable () async throws -> String = {
            try await fetchHTMLOnce(
                url: url,
                encoding: encoding,
                userAgent: userAgent,
                handlesCookies: handlesCookies,
                session: session
            )
        }
        do {
            let html = try await fetchHTMLOnce(
                url: url,
                encoding: encoding,
                userAgent: userAgent,
                handlesCookies: handlesCookies,
                session: session
            )
            return try await applyBotCheckGuard(url: url, body: html, retry: retry)
        } catch {
            return try await recoverFromBotCheckStatus(
                url: url,
                error: error,
                retry: retry,
                detector: BotCheckRegistry.detector(for: url),
                challenger: { challengeURL in
                    await BotCheckCoordinator.shared.challenge(url: challengeURL)
                }
            )
        }
    }

    private static func fetchHTMLOnce(
        url: URL,
        encoding: String.Encoding,
        userAgent: String?,
        handlesCookies: Bool,
        session: URLSession
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
