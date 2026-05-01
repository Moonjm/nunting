import Foundation

/// Session-lifetime in-memory cache of parsed first-page list snapshots,
/// keyed by `BoardListView.taskKey` (`"<boardID>|<filterID>|<searchQuery>"`).
/// Re-entering a recently visited board — a favorite, a swipe-step neighbour,
/// the previously opened board after a back-swipe — renders the cached list
/// instantly while a background revalidate fetches fresh content. Prefetch
/// (called when the drawer opens) populates the same cache so the first
/// drawer tap into a favorite is also instant.
///
/// Only first-page snapshots are stored. Once the user scrolls past page 1
/// via `loadMore`, the live `BoardListView` state owns the merged list; the
/// cache is not updated past page 1 because evicting paginated state on a
/// silent revalidate would jumble the user's scroll position.
///
/// Not persisted — a cold start drops everything so launches always show
/// fresh content.
@MainActor
final class BoardListCache {
    struct Entry {
        let posts: [Post]
        let hasMorePages: Bool
        let nextSearchURL: URL?
        let timestamp: Date
    }

    private var entries: [String: Entry] = [:]
    /// Oldest task key first. Touch-on-access keeps this LRU-ordered.
    private var order: [String] = []
    private let capacity: Int
    private let ttl: TimeInterval

    init(capacity: Int = 12, ttl: TimeInterval = 300) {
        self.capacity = capacity
        self.ttl = ttl
    }

    /// Mirrors `BoardListView.taskKey` so prefetched and live entries
    /// collide on the same key. `nonisolated` so the prefetch task group
    /// (running on a background utility queue) can build keys without
    /// hopping back to MainActor just for string interpolation.
    nonisolated static func key(boardID: String, filterID: String?, searchQuery: String?) -> String {
        "\(boardID)|\(filterID ?? "_all")|\(searchQuery ?? "")"
    }

    /// Returns the snapshot when present and within TTL. A stale entry is
    /// evicted and `nil` returned so the caller takes the cold-path with a
    /// visible spinner instead of rendering a likely-out-of-date list.
    func get(taskKey: String) -> Entry? {
        guard let entry = entries[taskKey] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > ttl {
            entries.removeValue(forKey: taskKey)
            if let idx = order.firstIndex(of: taskKey) {
                order.remove(at: idx)
            }
            return nil
        }
        touch(taskKey)
        return entry
    }

    func put(taskKey: String, posts: [Post], hasMorePages: Bool, nextSearchURL: URL?) {
        entries[taskKey] = Entry(
            posts: posts,
            hasMorePages: hasMorePages,
            nextSearchURL: nextSearchURL,
            timestamp: Date()
        )
        touch(taskKey)
        evictIfNeeded()
    }

    private func touch(_ key: String) {
        if let existing = order.firstIndex(of: key) {
            order.remove(at: existing)
        }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let victim = order.removeFirst()
            entries.removeValue(forKey: victim)
        }
    }
}

extension BoardListCache {
    /// Eagerly fetch + parse the default first-page view of each board on a
    /// background `.utility` task and store the result in `cache`. Called
    /// when the drawer opens so the typical "open drawer → tap favorite"
    /// sequence hits a warm cache and renders without a spinner.
    ///
    /// Best-effort throughout: failures are silent (the user just sees the
    /// spinner path on actual selection, identical to no-prefetch). Honors
    /// the same `defaultListFilter` the live `BoardListView` would apply,
    /// so the cache key collides with the live `taskKey` exactly.
    nonisolated static func prefetch(boards: [Board], into cache: BoardListCache) {
        let targets = boards
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for board in targets {
                    group.addTask {
                        await prefetchOne(board: board, into: cache)
                    }
                }
            }
        }
    }

    nonisolated private static func prefetchOne(board: Board, into cache: BoardListCache) async {
        let filter = board.defaultListFilter
        let key = key(boardID: board.id, filterID: filter?.id, searchQuery: nil)
        if await cache.get(taskKey: key) != nil { return }
        let url = board.url(filter: filter, search: nil, page: nil)
        guard let html = try? await Networking.fetchHTML(url: url, encoding: board.site.encoding),
              let parser = try? ParserFactory.parser(for: board.site),
              let parsed = try? parser.parseList(html: html, board: board)
        else { return }
        await cache.put(
            taskKey: key,
            posts: parsed,
            hasMorePages: board.supportsPaging,
            nextSearchURL: nil
        )
    }
}
