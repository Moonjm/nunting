import Foundation
import UIKit

/// Caps the number of concurrent `WKWebView`-backed inline WebM players
/// alive at once. Each WKWebView spawns a `WebContent` helper process
/// with a ~30-50 MB baseline residency — a long Etoland post with 5+
/// inline webm reactions can therefore peak at ~150-250 MB just on
/// WebView processes, on top of all image / AVPlayer / app caches.
/// Without a cap that's a primary contributor to jetsam kills during
/// detail-view mount.
///
/// Mirrors `VideoPlayerPool`'s eviction-and-waiter model so the
/// behaviour stays consistent across the two video paths:
///
/// 1. Refresh in place if the requesting view already holds a lease.
/// 2. Free slot available → grant.
/// 3. At cap → deny, queue as waiter. When some lease is released,
///    the oldest waiter is promoted via `tryRecreateWebView()`.
///
/// Difference from `VideoPlayerPool`: WebM has no notion of "paused but
/// still warm" — the AVPlayer pool can evict paused leases preferentially
/// because pausing a player is cheap; tearing down a WKWebView and
/// re-creating one later costs a full WebContent process spin-up (~200 ms
/// + 30 MB cold). So this pool stays strictly cap-and-wait: late views
/// see poster only until an earlier view releases.
///
/// `max = 2` (vs AVPlayer's 3) — WKWebView's per-instance memory weight
/// is meaningfully higher, and the typical "screen with one webm plus
/// one above/below" pattern only realises 1-2 simultaneously visible
/// instances anyway. 3 would push worst-case WebView residency to
/// ~150 MB on every post; 2 keeps it under ~100 MB.
///
/// `@MainActor` because the lease/waiter lists are touched from UIView
/// lifecycle methods (which SwiftUI runs on main).
@MainActor
final class WebMPlayerPool {
    static let shared = WebMPlayerPool()

    /// Public for tests to verify cap is enforced without depending on
    /// the production constant.
    static let maxConcurrent = 2

    /// Abstract lease holder. Production wires this to
    /// `WebmInlineWebView.Coordinator`; tests inject a stub that records
    /// `recreate()` invocations. Keeps the pool decoupled from WebKit
    /// imports — `WebMPlayerPool` itself only ever sees `AnyObject`s
    /// with a `recreate()` hook.
    protocol Leaseholder: AnyObject {
        /// Called when a previously-denied waiter is promoted because a
        /// slot freed. The leaseholder MUST call back into `acquire(...)`
        /// during this method; the pool granted the slot speculatively
        /// and counts on the immediate re-attempt to settle bookkeeping.
        func tryRecreateWebView()
    }

    private struct Lease {
        weak var holder: Leaseholder?
    }

    private struct Waiter {
        weak var holder: Leaseholder?
    }

    /// Front = oldest, back = newest.
    private var leases: [Lease] = []
    private var waiters: [Waiter] = []

    private init() {}

    /// Request a lease. Returns `true` if granted (caller should now
    /// create / show its WKWebView), `false` if denied (caller should
    /// stay WKWebView-less and wait — the pool will call
    /// `holder.tryRecreateWebView()` when a slot opens).
    @discardableResult
    func acquire(_ holder: Leaseholder) -> Bool {
        compactDeadRefs()

        // Already in pool: refresh position to back.
        if let i = leases.firstIndex(where: { $0.holder === holder }) {
            leases.remove(at: i)
            leases.append(Lease(holder: holder))
            removeFromWaiters(holder)
            return true
        }

        // Free slot.
        if leases.count < Self.maxConcurrent {
            leases.append(Lease(holder: holder))
            removeFromWaiters(holder)
            return true
        }

        // At cap. Queue as waiter (idempotent — the same holder asking
        // twice stays at its current waiter position).
        if !waiters.contains(where: { $0.holder === holder }) {
            waiters.append(Waiter(holder: holder))
        }
        return false
    }

    /// Full removal from both lease and waiter lists. Used by view
    /// teardown / dismantle. After this returns the freed slot may be
    /// granted to the oldest waiter.
    func release(_ holder: Leaseholder) {
        leases.removeAll { $0.holder === holder || $0.holder == nil }
        removeFromWaiters(holder)
        promoteWaiterIfPossible()
    }

    private func promoteWaiterIfPossible() {
        compactDeadRefs()
        guard !waiters.isEmpty, leases.count < Self.maxConcurrent else { return }
        let waiter = waiters.removeFirst()
        guard let holder = waiter.holder else {
            // Stale waiter; re-try the next one to keep draining.
            promoteWaiterIfPossible()
            return
        }
        // Hand control to the holder; it will call back into `acquire`
        // and (given the free slot check above) succeed.
        holder.tryRecreateWebView()
    }

    private func removeFromWaiters(_ holder: Leaseholder) {
        waiters.removeAll { $0.holder === holder || $0.holder == nil }
    }

    private func compactDeadRefs() {
        leases.removeAll { $0.holder == nil }
        waiters.removeAll { $0.holder == nil }
    }

    // MARK: - Test-only inspection

    #if DEBUG
    var leaseCount: Int { leases.count }
    var waiterCount: Int { waiters.count }
    func resetForTesting() {
        leases.removeAll()
        waiters.removeAll()
    }
    #endif
}
