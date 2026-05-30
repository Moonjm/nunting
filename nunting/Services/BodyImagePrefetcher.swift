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
    /// A dedicated instance (not `.shared`) so `cancel()` only tears down
    /// this screen's prefetch, never another consumer's.
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
        let start = index + 1
        let end = min(start + window, urls.count)
        guard start >= 0, start < end else { return [] }
        return urls[start..<end]
            .map(\.atsSafe)
            .filter { requested.insert($0).inserted }
    }

    /// Stop any in-flight prefetch — called when the screen tears down or its
    /// image set changes, so a closed post doesn't keep warming its tail.
    func cancel() {
        prefetcher.cancelPrefetching()
    }
}
