import Foundation
import SDWebImage
import UIKit

/// Central handler for `UIApplication.didReceiveMemoryWarningNotification`.
///
/// Primary value: flushes `URLCache.shared` (50 MB mem cap) — that layer
/// has no built-in memory-warning hook, so without this responder its
/// contents persist through pressure events. `SDImageCache.shared` is
/// also flushed for belt-and-suspenders, but `SDMemoryCache` already
/// self-registers for the same notification and calls `removeAllObjects`
/// on receipt (SDMemoryCache.m:69) — so our explicit call is redundant
/// with iOS's native delivery. Kept for explicit ordering + test seam.
///
/// Why a dedicated responder instead of inlining in `AppDelegate`:
/// the responder can be exercised by unit tests (post the notification,
/// assert caches cleared) without spinning up a `UIApplication`.
/// `AppDelegate.applicationDidReceiveMemoryWarning` also routes through
/// `MemoryPressureResponder.shared.respond()` so foreground warnings
/// land via either path (notification observer OR delegate callback —
/// iOS sends both, idempotent flush is safe).
///
/// The disk caches (SDImageCache 500 MB, URLCache 200 MB) are NOT
/// cleared — they don't contribute to memory pressure and dropping them
/// would force a cold re-download of recently-viewed bodies/images on
/// the next access. Only the in-memory layer is shed.
@MainActor
final class MemoryPressureResponder {
    static let shared = MemoryPressureResponder()

    /// Test seam — production wires this to the real `SDImageCache.shared`
    /// + `URLCache.shared` via `installDefaultHandlers`. Tests can inject
    /// spies that record invocation without touching the SDK singletons.
    var clearImageMemoryCache: @MainActor () -> Void = {}
    var clearURLMemoryCache: @MainActor () -> Void = {}

    private var observerToken: NSObjectProtocol?

    private init() {}

    /// Idempotent — calling start() twice replaces the previous observer.
    /// Bound to `applicationDidFinishLaunching` so the responder is live
    /// before the first detail view materialises.
    func start() {
        if let observerToken {
            NotificationCenter.default.removeObserver(observerToken)
        }
        observerToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Forced to main actor because the observer block above runs
            // on the queue passed in (`.main`), but Swift 6 strict
            // concurrency can't infer MainActor through the Notification
            // callback closure type. Hop explicitly.
            MainActor.assumeIsolated {
                self?.respond()
            }
        }
    }

    /// Public seam for AppDelegate's `applicationDidReceiveMemoryWarning`
    /// callback and for tests.
    func respond() {
        #if DEBUG
        print("[MemoryPressureResponder] memory warning — clearing in-memory caches")
        #endif
        clearImageMemoryCache()
        clearURLMemoryCache()
    }

    /// Production wiring — call once at launch (from `AppDelegate`).
    /// Splitting install from `start()` so tests can `start()` with
    /// injected spies without touching the real cache singletons.
    func installDefaultHandlers() {
        clearImageMemoryCache = {
            SDImageCache.shared.clearMemory()
        }
        clearURLMemoryCache = {
            URLCache.shared.removeAllCachedResponses()
        }
    }
}
