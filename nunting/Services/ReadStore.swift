import Foundation
import Observation

/// Tracks which posts the user has opened so the list view can dim them. Backed
/// by `UserDefaults`; insertion-order queue + cap keeps storage bounded.
@Observable
final class ReadStore {
    private let storageKey = "readPostIDs.v1"
    private let defaults: UserDefaults
    private let capacity: Int

    /// O(1) lookup; mirrors `order` content.
    private(set) var ids: Set<String>
    /// FIFO eviction queue — oldest first.
    private var order: [String]

    init(defaults: UserDefaults = .standard, capacity: Int = 5000) {
        self.defaults = defaults
        self.capacity = capacity
        var loadedOrder: [String] = []
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            // Trim if a previous build had a higher cap.
            loadedOrder = Array(decoded.suffix(capacity))
        }
        self.order = loadedOrder
        self.ids = Set(loadedOrder)
    }

    func isRead(_ post: Post) -> Bool { ids.contains(post.id) }

    func isRead(id: String) -> Bool { ids.contains(id) }

    func markRead(_ post: Post) {
        markRead(id: post.id)
    }

    func markRead(id: String) {
        guard ids.insert(id).inserted else { return }
        order.append(id)
        // Evict oldest entries until we're back under the cap.
        while order.count > capacity {
            let evicted = order.removeFirst()
            ids.remove(evicted)
        }
        persist()
    }

    /// Manual reset, e.g. for a future "기록 지우기" affordance.
    func clear() {
        ids = []
        order = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(order) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
