import Foundation
import Observation

/// Snapshot of a board persisted into UserDefaults so favorites survive even
/// when the dynamic catalog hasn't been fetched yet (or the upstream site
/// removed the board). Catalog re-fetches refresh the snapshots in place via
/// `merge(boards:)`, so renames/path changes still flow through.
struct FavoriteBoardSnapshot: Codable, Hashable {
    let id: String
    let siteRaw: String
    let name: String
    let path: String
    /// Optional so older v3 payloads (before this field existed) still decode;
    /// reconstruction defaults to `[]`.
    let filters: [BoardFilter]?
    let searchQueryName: String?
    let pageQueryName: String?

    nonisolated init(_ board: Board) {
        self.id = board.id
        self.siteRaw = board.site.rawValue
        self.name = board.name
        self.path = board.path
        self.filters = board.filters
        self.searchQueryName = board.searchQueryName
        self.pageQueryName = board.pageQueryName
    }

    var board: Board? {
        guard let site = Site(rawValue: siteRaw) else { return nil }
        return Board(
            id: id,
            site: site,
            name: name,
            path: path,
            filters: filters ?? [],
            searchQueryName: searchQueryName,
            pageQueryName: pageQueryName
        )
    }
}

@Observable
final class FavoritesStore {
    /// v3 stores an ordered array so the user can reorder favorites.
    private let storageKey = "favoriteBoards.v3"
    private let legacyV2Key = "favoriteBoards.v2"
    private let legacyIDKey = "favoriteBoardIDs"
    private let seededKey = "favoritesSeeded"
    private let defaults: UserDefaults

    private(set) var snapshots: [FavoriteBoardSnapshot]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // v3 (ordered array).
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([FavoriteBoardSnapshot].self, from: data) {
            self.snapshots = decoded
            return
        }

        // Migrate v2 (id → snapshot dict) by taking values in any order.
        if let data = defaults.data(forKey: legacyV2Key),
           let dict = try? JSONDecoder().decode([String: FavoriteBoardSnapshot].self, from: data) {
            self.snapshots = Array(dict.values).sorted { $0.name < $1.name }
            Self.persist(snapshots: self.snapshots, key: storageKey, defaults: defaults)
            return
        }

        // Migrate v1 (id-only Set) via Board.all lookup.
        if let data = defaults.data(forKey: legacyIDKey),
           let ids = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.snapshots = Board.all
                .filter { ids.contains($0.id) }
                .map(FavoriteBoardSnapshot.init)
            Self.persist(snapshots: self.snapshots, key: storageKey, defaults: defaults)
            return
        }

        // Fresh install: seed clien-news.
        if !defaults.bool(forKey: seededKey),
           let news = Board.all.first(where: { $0.id == Board.clienNews.id }) {
            self.snapshots = [FavoriteBoardSnapshot(news)]
            defaults.set(true, forKey: seededKey)
            Self.persist(snapshots: self.snapshots, key: storageKey, defaults: defaults)
            return
        }

        self.snapshots = []
    }

    func isFavorite(_ board: Board) -> Bool {
        snapshots.contains(where: { $0.id == board.id })
    }

    func toggle(_ board: Board) {
        if let idx = snapshots.firstIndex(where: { $0.id == board.id }) {
            snapshots.remove(at: idx)
        } else {
            snapshots.append(FavoriteBoardSnapshot(board))
        }
        persist()
    }

    func favoriteBoards() -> [Board] {
        snapshots.compactMap(\.board)
    }

    /// User-driven reorder, called from the favorites edit UI.
    /// Mirrors SwiftUI's `Array.move(fromOffsets:toOffset:)` semantics so it
    /// can be passed straight to `.onMove`.
    func move(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { snapshots[$0] }
        var result = snapshots
        // Remove from highest index down to keep earlier indices valid.
        for idx in source.sorted(by: >) { result.remove(at: idx) }
        let insertAt = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: max(0, min(insertAt, result.count)))
        snapshots = result
        persist()
    }

    /// Refresh snapshots whose IDs match boards just fetched from the catalog.
    /// Lets renames / path changes propagate without the user re-toggling, while
    /// preserving the user's chosen order.
    func merge(boards: [Board]) {
        var changed = false
        let byID = Dictionary(uniqueKeysWithValues: boards.map { ($0.id, $0) })
        for (idx, snapshot) in snapshots.enumerated() {
            guard let fresh = byID[snapshot.id] else { continue }
            let updated = FavoriteBoardSnapshot(fresh)
            if snapshots[idx] != updated {
                snapshots[idx] = updated
                changed = true
            }
        }
        if changed {
            persist()
        }
    }

    private func persist() {
        Self.persist(snapshots: snapshots, key: storageKey, defaults: defaults)
    }

    private static func persist(snapshots: [FavoriteBoardSnapshot], key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        defaults.set(data, forKey: key)
    }
}
