import Foundation
import UIKit

/// Caps the number of concurrent `AVPlayer` instances alive for inline
/// body videos. Each `InlineAutoplayUIView` requests a lease before
/// instantiating its player; when the pool is at capacity and a new view
/// arrives, the pool evicts the oldest paused leaseholder (preferred)
/// or denies the new request and queues it as a waiter (when every
/// existing lease is actively playing). Bounds memory residency on
/// long detail pages with many video blocks — each AVPlayer + its
/// decoded frame buffer is ~10-20 MB, so without a cap a 10-video
/// aagag long-form would peak ~150 MB just on players.
///
/// Eviction policy:
///   1. Refresh in place when the requesting view already holds a lease.
///   2. Free slot available → grant immediately.
///   3. At cap with at least one paused lease → evict oldest paused,
///      grant to requester.
///   4. At cap, every lease playing → deny, queue as waiter. When some
///      leaseholder later pauses (or releases entirely), the pool
///      promotes the oldest waiter via `tryRecreatePlayer()`.
///
/// The waiter path is the bug fix for "scroll past 4 visible videos →
/// the just-evicted-but-still-on-screen one stays on its poster forever
/// because no SwiftUI state change re-fires its `setPlaying`." Without
/// the explicit promotion callback, the view has no signal to retry
/// acquire and is stuck poster-only until the user scrolls it
/// off-and-back-on.
///
/// `@MainActor` because the lease/waiter lists are touched from UIView
/// lifecycle methods (which SwiftUI runs on main) and the eviction +
/// promotion callbacks fire UIView teardown / recreate — both must
/// stay on the main thread.
@MainActor
final class VideoPlayerPool {
    static let shared = VideoPlayerPool()

    /// Maximum concurrent AVPlayer instances. 3 covers the typical
    /// "screen with one video plus immediate above/below buffer"
    /// pattern that LazyVStack realises, leaves room for one
    /// just-out-of-viewport entry the user is likely to scroll back
    /// to, and keeps the worst-case AVPlayer residency under ~60 MB.
    private static let maxConcurrent = 3

    private struct Lease {
        weak var view: InlineAutoplayUIView?
        /// `false` while the view's `setPlaying(true)` is the most
        /// recent state, `true` after `notifyPaused`. Eviction prefers
        /// paused entries — playing entries are only evicted when
        /// every other lease is also playing AND a new acquire arrives,
        /// in which case the displaced view goes to the waiter list.
        var isPaused: Bool
    }

    private struct Waiter {
        weak var view: InlineAutoplayUIView?
    }

    /// Front = oldest, back = newest. Eviction prefers paused entries
    /// from the front of the list.
    private var leases: [Lease] = []
    /// Views that asked for a lease but were denied because every
    /// existing lease was playing. Drained in FIFO order whenever a
    /// lease pauses or releases.
    private var waiters: [Waiter] = []

    private init() {}

    /// Request a lease for `view`. Returns `true` if granted (caller
    /// should now create/use its AVPlayer), `false` if denied (caller
    /// should stay player-less and wait — the pool will call
    /// `view.tryRecreatePlayer()` when a slot opens).
    @discardableResult
    func acquire(_ view: InlineAutoplayUIView) -> Bool {
        compactDeadRefs()

        // Already in pool: refresh position to back, clear paused
        // flag. Equivalent to a fresh acquire from eviction-policy
        // perspective.
        if let i = leases.firstIndex(where: { $0.view === view }) {
            leases.remove(at: i)
            leases.append(Lease(view: view, isPaused: false))
            removeFromWaiters(view)
            return true
        }

        // Free slot.
        if leases.count < Self.maxConcurrent {
            leases.append(Lease(view: view, isPaused: false))
            removeFromWaiters(view)
            return true
        }

        // At cap. Try to evict an oldest paused entry first — these
        // are off-screen or fullscreen-occluded views that don't
        // need their decoder right now.
        if let pausedIdx = leases.firstIndex(where: { $0.isPaused }) {
            let evicted = leases.remove(at: pausedIdx)
            evicted.view?.releasePlayerForPoolEviction()
            leases.append(Lease(view: view, isPaused: false))
            removeFromWaiters(view)
            return true
        }

        // All leases playing. Deny + queue. Caller (the view)
        // should render its poster only and wait for the pool's
        // promotion callback. Idempotent: the same view asking
        // twice in a row stays at its current waiter position.
        if !waiters.contains(where: { $0.view === view }) {
            waiters.append(Waiter(view: view))
        }
        return false
    }

    /// View tells pool it paused but still wants to keep its lease
    /// (e.g. fullscreen cover up, scrolled to viewport edge). Marks
    /// the slot as eviction-eligible and promotes a waiter if one is
    /// queued — the just-paused slot can now be ceded to a waiting
    /// visible view.
    func notifyPaused(_ view: InlineAutoplayUIView) {
        if let i = leases.firstIndex(where: { $0.view === view }) {
            leases[i].isPaused = true
        }
        promoteWaiterIfPossible()
    }

    /// Full removal from both lease and waiter lists. Used by view
    /// teardown / dismantle / URL change. After this returns the
    /// freed slot may be granted to the oldest waiter.
    func release(_ view: InlineAutoplayUIView) {
        leases.removeAll { $0.view === view || $0.view == nil }
        removeFromWaiters(view)
        promoteWaiterIfPossible()
    }

    private func promoteWaiterIfPossible() {
        compactDeadRefs()
        guard !waiters.isEmpty else { return }
        // Grant only if we'd actually succeed: free slot or at least
        // one paused lease. Otherwise leave the waiter where they
        // are; another `notifyPaused`/`release` will re-trigger.
        let canGrant = leases.count < Self.maxConcurrent
            || leases.contains(where: { $0.isPaused })
        guard canGrant else { return }
        let waiter = waiters.removeFirst()
        guard let view = waiter.view else {
            // Stale waiter; re-try with the next one to keep draining.
            promoteWaiterIfPossible()
            return
        }
        // Hand control to the view; it will call back into `acquire`
        // and (given canGrant above) succeed.
        view.tryRecreatePlayer()
    }

    private func removeFromWaiters(_ view: InlineAutoplayUIView) {
        waiters.removeAll { $0.view === view || $0.view == nil }
    }

    private func compactDeadRefs() {
        leases.removeAll { $0.view == nil }
        waiters.removeAll { $0.view == nil }
    }
}
