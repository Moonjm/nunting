import Foundation
import SDWebImage
import UIKit

/// Central handler for `UIApplication.didReceiveMemoryWarningNotification`.
///
/// Primary value: flushes `URLCache.shared` (50 MB mem cap) — that layer
/// has no built-in memory-warning hook, so without this responder its
/// contents persist through pressure events. `AppImageCaches.disk` is
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
///
/// 그 계약이 URLCache 쪽에서 한동안 깨져 있었다: `removeAllCachedResponses()`
/// 는 이름과 달리 메모리 **와 디스크**를 전부 비운다. 그래서 메모리 경고 한
/// 번에 200MB 디스크 응답 캐시까지 통째로 날아갔다 — 압박 완화에 기여하는
/// 부분은 하나도 없으면서 다음 접근을 전부 콜드로 만드는 순손실. URLCache 엔
/// "메모리만" API 가 없으므로 `memoryCapacity` 를 0 으로 내렸다 되돌리는
/// 문서화된 절단 동작(setter 는 호출 시점에 인메모리 내용을 주어진 크기로
/// truncate 한다)으로 대체한다. 디스크는 그대로 남는다.
@MainActor
final class MemoryPressureResponder {
    static let shared = MemoryPressureResponder()

    /// Test seam — production wires this to the real `AppImageCaches.disk`
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
            AppImageCaches.disk.clearMemory()
        }
        clearURLMemoryCache = {
            // 디스크는 건드리지 않는다 — 위 doccomment 참조.
            let cache = URLCache.shared
            let capacity = cache.memoryCapacity
            cache.memoryCapacity = 0
            cache.memoryCapacity = capacity
        }
    }
}
