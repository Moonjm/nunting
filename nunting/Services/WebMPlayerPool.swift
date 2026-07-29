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
/// 3. At cap with an off-screen (paused) lease → evict the oldest paused
///    one and grant.
/// 4. At cap with every lease on-screen → deny, queue as waiter. When a
///    lease is released or pauses, the oldest waiter is promoted via
///    `tryRecreateWebView()`.
///
/// Rule 3 exists because the host stacks are **eager** (article body and
/// comment list both materialise every row up-front, for scroll-position
/// stability). A lease tied to view lifetime therefore never comes back:
/// the first two webm views hold both slots for as long as the detail is
/// open and every later webm stays poster-only forever. Tying the lease
/// to viewport visibility instead is what makes the cap work under eager
/// layout — the same model `VideoPlayerPool` already uses for AVPlayer.
///
/// The WebM-specific cost is that recreating a WKWebView is a full
/// WebContent process spin-up (~200 ms + 30 MB cold) and playback
/// restarts from zero, so eviction is *only* used to satisfy real
/// contention: a paused lease is kept warm as long as nobody else needs
/// the slot.
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
        /// The pool pulled this holder's (paused) lease to make room for
        /// another view. The holder should tear its WKWebView down; it
        /// re-acquires on its next visible transition.
        func releaseWebViewForPoolEviction()
    }

    private struct Lease {
        weak var holder: Leaseholder?
        /// `true` once the holder reported going off-screen
        /// (`notifyPaused`). Only paused leases are eviction-eligible, so
        /// a webm the user is actually looking at is never pulled out
        /// from under them.
        var isPaused: Bool
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

        // Already in pool: refresh position to back, clear paused flag.
        if let i = leases.firstIndex(where: { $0.holder === holder }) {
            leases.remove(at: i)
            leases.append(Lease(holder: holder, isPaused: false))
            removeFromWaiters(holder)
            return true
        }

        // Free slot.
        if leases.count < Self.maxConcurrent {
            leases.append(Lease(holder: holder, isPaused: false))
            removeFromWaiters(holder)
            return true
        }

        // At cap. Evict the oldest off-screen lease if there is one — its
        // WKWebView isn't showing anything the user can see, and under
        // eager layout that is the only way a slot ever frees up.
        if let pausedIdx = leases.firstIndex(where: { $0.isPaused }) {
            let evicted = leases.remove(at: pausedIdx)
            evicted.holder?.releaseWebViewForPoolEviction()
            leases.append(Lease(holder: holder, isPaused: false))
            removeFromWaiters(holder)
            return true
        }

        // Every lease is on-screen. Queue as waiter (idempotent — the same
        // holder asking twice stays at its current waiter position).
        if !waiters.contains(where: { $0.holder === holder }) {
            waiters.append(Waiter(holder: holder))
        }
        return false
    }

    /// Holder went off-screen but keeps its WKWebView warm. Marks the
    /// slot eviction-eligible and hands it to a waiting on-screen view if
    /// one is queued — the whole point of the visibility-tied lease.
    func notifyPaused(_ holder: Leaseholder) {
        if let i = leases.firstIndex(where: { $0.holder === holder }) {
            leases[i].isPaused = true
        }
        promoteWaiterIfPossible()
    }

    /// Holder came back on-screen while still holding its lease. Clears
    /// the paused flag and refreshes recency so a still-visible webm
    /// can't be evicted by a later acquire — mirrors
    /// `VideoPlayerPool.notifyResumed`.
    func notifyResumed(_ holder: Leaseholder) {
        guard let i = leases.firstIndex(where: { $0.holder === holder }) else { return }
        leases.remove(at: i)
        leases.append(Lease(holder: holder, isPaused: false))
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
        guard !waiters.isEmpty else { return }
        // Grant only when the promoted holder's `acquire` will actually
        // succeed: a free slot, or a paused lease it can evict.
        let canGrant = leases.count < Self.maxConcurrent
            || leases.contains(where: { $0.isPaused })
        guard canGrant else { return }
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
    var pausedLeaseCount: Int { leases.lazy.filter { $0.isPaused }.count }
    func resetForTesting() {
        leases.removeAll()
        waiters.removeAll()
    }
    #endif
}
