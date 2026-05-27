import Foundation

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

extension Networking {
    /// Rewrites `http://` redirect targets to `https://` before URLSession
    /// follows them. Some upstream sites (observed on Clien when the guest
    /// session cookie is stale) issue a 30x with an `http://` Location, which
    /// App Transport Security then blocks and surfaces as "The resource could
    /// not be loaded because the App Transport Security policy requires the
    /// use of a secure connection." All boards we scrape serve HTTPS on the
    /// same host, so a blind upgrade is safe and avoids an ATS exception.
    final class RedirectHTTPSUpgrader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
            // Share the URL transform with `URL.atsSafe` so this and the
            // SDWebImage-side `HTTPSRedirectingDownloaderOperation` stay
            // converged — any future change (host blocklist, scheme rules)
            // lands in one place.
            guard let url = request.url, url.scheme?.lowercased() == "http" else {
                completionHandler(request)
                return
            }
            var upgradedRequest = request
            upgradedRequest.url = url.atsSafe
            completionHandler(upgradedRequest)
        }
    }

    // Stateless delegate (no stored mutable properties); `nonisolated` so it
    // doesn't pull the `session` initializer (in `Networking.swift`) into
    // MainActor inference.
    nonisolated static let redirectUpgrader = RedirectHTTPSUpgrader()

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
                // Bot-check status surface: when the host answers with a
                // challenge-indicating status (e.g. Aagag's 303 self-loop)
                // we bail out of the resolver entirely. Returning the
                // 303-page body as `prefetchedBody` would feed an
                // interstitial into the downstream parser AND skip
                // `fetchHTML`'s catch path that routes the same condition
                // through `BotCheckCoordinator`. Falling through to nil
                // lets `PostDetailLoader` request the URL via `fetchHTML`,
                // which owns the challenge surface.
                if let http = response as? HTTPURLResponse,
                   BotCheckRegistry.statusIndicatesChallenge(for: url, status: http.statusCode) {
                    return nil
                }
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
}
