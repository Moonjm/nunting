import Foundation

/// Session-lifetime in-memory cache of fully-loaded detail pages. Re-entering
/// a post — whether by tapping it again or via the right-edge forward-swipe
/// gesture in `ContentView` — skips the network fetch + SwiftSoup parse and
/// restores the article instantly. The cache is intentionally not persisted
/// to disk: a cold start drops it, so users who relaunch get fresh content
/// automatically.
/// `@MainActor` so the unsynchronised `entries` / `order` dictionary can't
/// be reached from a background task by accident. All current call sites
/// (PostDetailView's `.task`, load path, ContentView State init) are already
/// main-actor, so this is an isolation seal rather than a behaviour change.
@MainActor
final class PostDetailCache {
    struct Entry {
        let detail: PostDetail
    }

    private var entries: [String: Entry] = [:]
    /// Oldest post.id first. Touch-on-access keeps this LRU-ordered.
    private var order: [String] = []
    private let capacity: Int

    init(capacity: Int = 20) {
        self.capacity = capacity
    }

    func get(id: String) -> Entry? {
        guard let entry = entries[id] else { return nil }
        touch(id)
        return entry
    }

    func put(id: String, detail: PostDetail) {
        entries[id] = Entry(detail: detail)
        touch(id)
        evictIfNeeded()
    }

    private func touch(_ id: String) {
        if let existing = order.firstIndex(of: id) {
            order.remove(at: existing)
        }
        order.append(id)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let victim = order.removeFirst()
            entries.removeValue(forKey: victim)
        }
    }
}
