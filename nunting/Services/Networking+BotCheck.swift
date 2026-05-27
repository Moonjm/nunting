import Foundation

/// Per-host detector lookup. When `fetchHTML` lands a successful response,
/// it checks whether the URL host has a registered detector and, if so,
/// runs it against the decoded body. A `true` return triggers the
/// `BotCheckCoordinator` interactive flow.
///
/// Detectors are intentionally narrow heuristics — false negatives just
/// let the body flow through to the parser (which will likely fail in
/// its own way), false positives cost a wasted retry trip.
enum BotCheckRegistry {
    nonisolated static func detector(for url: URL) -> (@Sendable (String) -> Bool)? {
        if Site.host(url.host, matches: "aagag.com") {
            return AagagParser.looksLikeBotCheck(html:)
        }
        return nil
    }

    /// Host-scoped status-code signal for the bot-check surface. Aagag
    /// returns 303 redirects (often self-loops) to a captcha gate when
    /// it has judged the client as a bot; URLSession's auto-follow then
    /// gives up and `fetchHTMLOnce` throws `NetworkError.badResponse(303)`
    /// before the body-based detector ever runs. This predicate lets the
    /// outer `fetchHTML` catch path treat that specific error as a
    /// challenge signal and trigger the same coordinator flow, instead
    /// of surfacing a bare "HTTP 303" to the user.
    ///
    /// Stays host-scoped so a 303 from a normal redirecting site can't
    /// hijack into the captcha sheet path.
    nonisolated static func statusIndicatesChallenge(for url: URL, status: Int) -> Bool {
        if Site.host(url.host, matches: "aagag.com") {
            return status == 303
        }
        return false
    }
}

extension Networking {
    /// Catch-and-recover seam for the status-surface bot-check path.
    /// Extracted from `fetchHTML` so the contract (challenger fires for
    /// the registered status only, post-recovery retry collapses both
    /// status- and body-side re-detection into `.captchaChallenge`) can
    /// be driven by tests without standing up a real URLSession or the
    /// `BotCheckCoordinator` sheet.
    ///
    /// `challenger` is the side-effect — production wires it to
    /// `BotCheckCoordinator.shared.challenge(url:)`; tests inject a spy
    /// that records the URL it was invited to challenge. `detector`
    /// stays optional because callers may have no host-specific
    /// detector registered (in which case the post-retry body check is
    /// skipped and only a re-thrown status loops back to
    /// `.captchaChallenge`).
    ///
    /// Errors that don't match the host's challenge-status predicate
    /// are re-thrown untouched — this seam is invisible to the rest of
    /// the error surface (404 / 500 / URLError / cancellation all
    /// bubble straight up).
    static func recoverFromBotCheckStatus(
        url: URL,
        error: Error,
        retry: @Sendable () async throws -> String,
        detector: (@Sendable (String) -> Bool)?,
        challenger: @Sendable (URL) async -> Void
    ) async throws -> String {
        guard case NetworkError.badResponse(let code) = error,
              BotCheckRegistry.statusIndicatesChallenge(for: url, status: code)
        else { throw error }

        #if DEBUG
        print("[Networking] bot-check status \(code) for \(url.absoluteString); presenting challenge sheet")
        #endif
        await challenger(url)
        do {
            let retried = try await retry()
            if detector?(retried) == true {
                throw NetworkError.captchaChallenge(url)
            }
            return retried
        } catch let NetworkError.badResponse(retryCode)
                    where BotCheckRegistry.statusIndicatesChallenge(for: url, status: retryCode) {
            // Sheet completed but the host is still answering 303 —
            // either cookie bridging failed or the user dismissed the
            // captcha. Collapse into the same `.captchaChallenge` that
            // a still-blocked retry body produces so the loader's catch
            // path renders the unified message and the sheet doesn't
            // loop.
            throw NetworkError.captchaChallenge(url)
        }
    }

    /// Runs the per-host bot-check detector against `body`. If it
    /// matches, suspends on `BotCheckCoordinator` (which presents the
    /// SwiftUI sheet) and invokes `retry` once after the user resolves
    /// it; the retry response is checked again and either returned or
    /// surfaced as `NetworkError.captchaChallenge` to break the loop.
    ///
    /// Shared between `fetchHTML` (normal HTTP path) and
    /// `PostDetailLoader`'s prefetched-body path (where
    /// `resolveFinalURL`'s GET captured the response body and the
    /// caller would otherwise hand it straight to a parser, bypassing
    /// the detector). Aagag mirror items always go through the
    /// prefetched path, so this dual-call site coverage is required
    /// to actually catch the most likely real-world challenge entry
    /// point.
    static func applyBotCheckGuard(
        url: URL,
        body: String,
        retry: @Sendable () async throws -> String
    ) async throws -> String {
        guard let detector = BotCheckRegistry.detector(for: url), detector(body) else {
            return body
        }
        #if DEBUG
        // First-occurrence body capture so we can tighten the per-host
        // detector to an exact marker. Truncate to keep log noise bounded.
        let preview = body.prefix(1500)
        print("[Networking] bot-check detected for \(url.absoluteString); body preview:\n\(preview)")
        #endif
        await BotCheckCoordinator.shared.challenge(url: url)
        let retried = try await retry()
        if detector(retried) {
            // Still blocked after the user-driven recovery — surface as
            // an error rather than looping the sheet. The loader's catch
            // path will render the localized message.
            throw NetworkError.captchaChallenge(url)
        }
        return retried
    }
}
