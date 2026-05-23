import Foundation
import Observation

/// Coordinates the "site served a bot-check page" interactive recovery flow:
/// 1. `Networking.fetchHTML` decides a response body looks like a CAPTCHA
///    interstitial (via a per-host detector) and calls
///    `BotCheckCoordinator.shared.challenge(url:)`.
/// 2. This actor stores the pending challenge URL; the SwiftUI root view
///    observes `pending` and presents `BotCheckSheet` with that URL.
/// 3. The user solves the CAPTCHA inside the sheet's WKWebView. The sheet
///    copies cookies from `WKHTTPCookieStore` into `HTTPCookieStorage.shared`
///    (so subsequent URLSession requests carry the freshly-issued session
///    cookie) and signals completion back here.
/// 4. `challenge(url:)` resumes; `Networking.fetchHTML` re-fetches the same
///    URL — the cookies make it through the bot-check, the caller sees the
///    real body.
///
/// Singleton so the nonisolated networking layer has a fixed access point.
/// The pending state is read from `@MainActor` SwiftUI; the await in
/// `challenge(url:)` crosses isolation but Swift handles that transparently.
@Observable
@MainActor
final class BotCheckCoordinator {
    static let shared = BotCheckCoordinator()

    /// Wraps URL with an Identifiable conformance so SwiftUI's `.sheet(item:)`
    /// can use it directly. Identity is the URL itself — two simultaneous
    /// challenges to the same URL collapse into one sheet presentation.
    struct PendingChallenge: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
    }

    /// Non-nil while the sheet is presented. SwiftUI binds to this; setting
    /// it to nil dismisses the sheet.
    private(set) var pending: PendingChallenge?

    /// Continuations of all `challenge(url:)` callers waiting for the user
    /// to solve the current CAPTCHA. Multiple in-flight fetches (e.g. list +
    /// detail concurrently) collapse onto a single sheet; resolving the
    /// sheet wakes them all so each can retry.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// Call from `Networking.fetchHTML` after detecting a bot-check body.
    /// Suspends until the user has solved the CAPTCHA (or dismissed the
    /// sheet — in which case the retry will likely fail again but the
    /// caller path is the same).
    ///
    /// When multiple concurrent fetches challenge simultaneously, only
    /// the URL of the FIRST caller is shown in the WebView — all later
    /// waiters' URLs are ignored (intentionally: solving a single
    /// challenge typically mints a domain-scoped session cookie that
    /// covers every other URL in flight). If a future site uses a
    /// path-bound challenge cookie, this collapse logic needs to grow
    /// a per-URL queue.
    func challenge(url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
            // First waiter triggers sheet presentation; subsequent waiters
            // just join the wake-list.
            if pending == nil {
                pending = PendingChallenge(url: url)
            }
        }
    }

    /// Called by `BotCheckSheet` when navigation lands on a non-challenge
    /// page (user solved it) or the user manually dismissed. Wakes every
    /// waiter so each can retry its own fetch.
    func resolve() {
        pending = nil
        let toResume = waiters
        waiters.removeAll()
        for continuation in toResume {
            continuation.resume()
        }
    }
}
