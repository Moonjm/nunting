import Foundation
import Observation
/// Snapshot of a board persisted into UserDefaults so favorites survive even
/// when the dynamic catalog hasn't been fetched yet (or the upstream site
/// removed the board). Catalog re-fetches refresh the snapshots in place via
/// `merge(boards:)`, so renames/path changes still flow through.
nonisolated struct FavoriteBoardSnapshot: Codable, Hashable, Sendable {
    let id: String
    let siteRaw: String
    let name: String
    let path: String
    let filters: [BoardFilter]
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
            filters: filters,
            searchQueryName: searchQueryName,
            pageQueryName: pageQueryName
        )
    }
}

@Observable
final class FavoritesStore {
    /// v3 stores an ordered array so the user can reorder favorites.
    private let storageKey = "favoriteBoards.v3"
    private let seededKey = "favoritesSeeded"
    private let defaults: UserDefaults

    private(set) var snapshots: [FavoriteBoardSnapshot]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // v3 (ordered array).
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([FavoriteBoardSnapshot].self, from: data) {
            self.snapshots = decoded
            // Statically-defined boards (Board.all) own their `filters` /
            // `path` definitions in source — refresh persisted snapshots
            // against the current source-of-truth so structural updates
            // (new filter chips, renamed paths) propagate on app upgrade
            // without requiring the user to navigate into a site section
            // (which is the only other place `merge(boards:)` is wired).
            merge(boards: Board.all)
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
