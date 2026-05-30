import Foundation
import SDWebImage

/// Look-ahead prefetcher for a detail screen's body images.
///
/// Body images render through `NetworkImage(visibilityGated: true)`, which
/// defers each fetch until the image scrolls into the viewport — that bounds
/// the fetch burst on a 30-image post, but it also means every scroll lands
/// on a *cold* image (gray placeholder → late fill). This coordinator warms
/// the next `window` images each time one becomes visible, at low priority,
/// so the user scrolls into cache hits without reintroducing the burst the
/// gate exists to prevent.
///
/// Bounded + dedup'd: each URL is prefetched at most once, and only `window`
/// ahead of the most-recently-seen image are ever in flight. Low priority
/// means on-screen (gated / eager) fetches always win the downloader's
/// concurrency slots — prefetch fills idle capacity only.
@MainActor
final class BodyImagePrefetcher {
    /// Body image URLs in document order. Index passed to
    /// `imageBecameVisible(at:)` is a position in this list.
    private let urls: [URL]
    private let window: Int
    /// A dedicated instance (not `.shared`) so `cancel()` only drops this
    /// screen's prefetch tokens, never another consumer's. Note the
    /// underlying `SDWebImageDownloader` / `SDImageCache` are still the shared
    /// singletons — which is exactly why `.lowPriority` matters: prefetch and
    /// on-screen loads compete for the same 4 downloader slots, and the
    /// priority is what lets visible images win.
    private let prefetcher = SDWebImagePrefetcher()
    /// URLs already handed to the prefetcher — never re-issued.
    private var requested = Set<URL>()

    init(urls: [URL], window: Int = 3) {
        self.urls = urls
        self.window = window
    }

    /// The image at `index` became visible — warm the next `window` URLs that
    /// haven't been queued yet. No-op when `index` is out of range (e.g. a
    /// stale callback after the URL list changed) or when nothing fresh
    /// remains ahead.
    func imageBecameVisible(at index: Int) {
        let fresh = claimFreshURLs(forVisibleIndex: index)
        guard !fresh.isEmpty else { return }
        // `.lowPriority` yields the 4 downloader slots to on-screen loads;
        // prefetch only consumes otherwise-idle capacity.
        _ = prefetcher.prefetchURLs(fresh, options: .lowPriority, context: nil, progress: nil, completed: nil)
    }

    /// The not-yet-requested `atsSafe` URLs in the `window` ahead of
    /// `index`, marking them requested as a side effect. Split out from
    /// `imageBecameVisible(at:)` so the window-bounds + dedup math is unit
    /// testable without driving `SDWebImagePrefetcher`'s side effects.
    ///
    /// `atsSafe` matches the exact URL `NetworkImage` loads, so the prefetch
    /// warms the same `SDImageCache` key the on-screen fetch will later hit —
    /// a raw `http://` URL would cache under a different key and the prefetch
    /// would be wasted.
    func claimFreshURLs(forVisibleIndex index: Int) -> [URL] {
        guard index >= 0 else { return [] }
        // The visible image is loaded by its on-screen `NetworkImage`, not by
        // the prefetcher — mark it requested so a later duplicate occurrence
        // of the same image isn't redundantly warmed.
        if index < urls.count { requested.insert(urls[index].atsSafe) }
        let start = index + 1
        let end = min(start + window, urls.count)
        guard start < end else { return [] }
        // Explicit loop rather than `filter { requested.insert(...).inserted }`
        // — mutating `requested` inside a functional chain is an anti-pattern
        // that would silently break under a future `.lazy`.
        var fresh: [URL] = []
        for url in urls[start..<end] {
            let safe = url.atsSafe
            if requested.insert(safe).inserted { fresh.append(safe) }
        }
        return fresh
    }

    /// Stop any in-flight prefetch. Called when the overlay hides
    /// (`isOverlayVisible` → false) or the image set changes (post swap /
    /// pull-to-refresh) so a left-behind post doesn't keep warming its tail.
    /// The detail overlay is keep-alive (it survives dismissal with only an
    /// offset animation), so cancellation is driven by those explicit signals
    /// rather than `.onDisappear`, which doesn't fire on a normal dismiss.
    func cancel() {
        prefetcher.cancelPrefetching()
    }
}
