import Foundation
import Observation

@Observable
final class FavoritesStore {
    private let storageKey = "favoriteBoardIDs"
    private let seededKey = "favoritesSeeded"
    private let defaults: UserDefaults
    var boardIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            self.boardIDs = decoded
        } else if defaults.bool(forKey: seededKey) {
            self.boardIDs = []
        } else {
            let seeded: Set<String> = [Board.clienNews.id]
            self.boardIDs = seeded
            defaults.set(true, forKey: seededKey)
            Self.persist(boardIDs: seeded, key: storageKey, defaults: defaults)
        }
    }

    func isFavorite(_ board: Board) -> Bool {
        boardIDs.contains(board.id)
    }

    func toggle(_ board: Board) {
        if boardIDs.contains(board.id) {
            boardIDs.remove(board.id)
        } else {
            boardIDs.insert(board.id)
        }
        Self.persist(boardIDs: boardIDs, key: storageKey, defaults: defaults)
    }

    func favoriteBoards(in registry: [Board] = Board.all) -> [Board] {
        registry.filter { boardIDs.contains($0.id) }
    }

    private static func persist(boardIDs: Set<String>, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(boardIDs) else { return }
        defaults.set(data, forKey: key)
    }
}
