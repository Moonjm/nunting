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

    /// Tail of the persist task chain. Each `persist()` call awaits this
    /// before writing so concurrent detached tasks can't reorder their
    /// `defaults.set` calls and leave a stale snapshot on disk.
    /// `@ObservationIgnored` because no SwiftUI view should ever depend
    /// on the persist queue's identity.
    @ObservationIgnored
    private var pendingPersist: Task<Void, Never>?

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

    /// Snapshot the FIFO list and offload JSON encoding + UserDefaults
    /// write to a background task so a `markRead` triggered by the user's
    /// detail-open tap doesn't pay an inline ~80 KB encode (full 5000-ID
    /// cap) on the main actor before the overlay can animate in.
    /// Snapshotting `order` up-front isolates the background work from
    /// later in-memory mutations.
    ///
    /// Two concurrency invariants need to hold:
    /// 1. **Order**: rapid `markRead`s enqueue snapshots S1 → S2 → S3
    ///    where each one is a superset of the previous. If detached
    ///    tasks at the same priority interleave their `defaults.set`
    ///    calls (which they can — separate tasks have no FIFO guarantee
    ///    on the cooperative pool), an older snapshot can overwrite a
    ///    newer one and silently drop ids until the next mutation.
    ///    Each task chains `await previous?.value` so the writes serialize.
    /// 2. **Durability under app-kill**: a tap-then-immediate-kill must
    ///    not lose the read state for the post the user just opened.
    ///    `.utility` is demotable under thermal/battery pressure and
    ///    explicitly low-priority; `.userInitiated` keeps the write at
    ///    the same QoS as the user's interactive workload, which is the
    ///    correct floor for "this write reflects an action the user just
    ///    performed."
    private func persist() {
        let snapshot = order
        let key = storageKey
        // nonisolated(unsafe): UserDefaults 는 문서상 thread-safe 지만 SDK 가
        // Sendable 로 표시하지 않아, Swift 6 모드에서 detached 클로저 캡처가
        // sending 위반으로 잡힌다. 실제 경합 없음(아래 태스크 체인이 쓰기를
        // 직렬화).
        nonisolated(unsafe) let store = defaults
        let previous = pendingPersist
        pendingPersist = Task.detached(priority: .userInitiated) {
            _ = await previous?.value
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            store.set(data, forKey: key)
        }
    }
}
