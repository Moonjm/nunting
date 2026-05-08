import Foundation
import UIKit

/// Caps the number of concurrent `AVPlayer` instances alive for inline
/// body videos. Each `InlineAutoplayUIView` requests a lease before
/// instantiating its player; when the pool is at capacity and a new view
/// arrives, the least-recently-leased view is told to release its
/// player. Bounds memory residency on long detail pages with many video
/// blocks — each AVPlayer + its decoded frame buffer is ~10-20 MB, so
/// without a cap a 10-video aagag long-form would peak ~150 MB just on
/// players.
///
/// Eviction policy: pure FIFO of acquire timestamps. Refined eviction
/// (prefer-paused-over-playing, prefer-off-screen-over-on-screen) was
/// considered but dropped — on iPhone viewport sizes only 1-2 videos
/// can be on-screen at once, so the LRU entry is essentially always an
/// off-screen one already.
///
/// `@MainActor` because the lease list is touched from
/// `InlineAutoplayUIView` lifecycle methods (which SwiftUI runs on
/// main) and the eviction callback fires UIView teardown — both must
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
    }

    /// Front = oldest, back = newest. Eviction takes from front.
    private var leases: [Lease] = []

    private init() {}

    /// Register a view as needing a player. May evict the oldest
    /// existing leaseholder to stay under `maxConcurrent`. Idempotent
    /// for an already-registered view: re-acquiring just refreshes the
    /// view's position to the back of the queue (so a recently-active
    /// player isn't first to be evicted by the next `acquire`).
    func acquire(_ view: InlineAutoplayUIView) {
        // Compact dead refs from prior dismantles that didn't hit
        // `release` (e.g. SwiftUI dropped the representable without a
        // dismantle event — rare, but the WeakBox guards against it).
        leases.removeAll { $0.view == nil }
        // Refresh: drop any existing entry for this view so the
        // re-append below puts it at the back.
        leases.removeAll { $0.view === view }
        // Evict oldest until under cap. Loop instead of single removal
        // so a backlog from compaction doesn't leave us over.
        while leases.count >= Self.maxConcurrent {
            if let oldest = leases.first?.view {
                oldest.releasePlayerForPoolEviction()
            }
            leases.removeFirst()
        }
        leases.append(Lease(view: view))
    }

    /// Drop a view's lease without telling the view to release its
    /// player — the view itself is doing teardown and will release in
    /// its own cleanup. Use `acquire` from a different view to actively
    /// kick this one's player out.
    func release(_ view: InlineAutoplayUIView) {
        leases.removeAll { $0.view === view || $0.view == nil }
    }
}
