import XCTest
@testable import nunting
/// Persistence tests for `FavoritesStore`.
///
/// Each test uses an isolated `UserDefaults(suiteName:)` so cases don't
/// leak state into each other. The store's constructor already accepts
/// an injected `UserDefaults`, which is the only seam needed to keep
/// tests hermetic.
// @MainActor: 검증 대상 스토어/로더가 main actor 소속 — Swift 6 모드에서
// nonisolated 테스트가 동기 접근할 수 없어 테스트 클래스를 main actor 로 올린다.
@MainActor
final class FavoritesStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FavoritesStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Fresh install seeding

    func testFreshInstallSeedsClienNews() {
        let store = FavoritesStore(defaults: defaults)
        let boards = store.favoriteBoards()
        XCTAssertEqual(boards.count, 1)
        XCTAssertEqual(boards.first?.id, Board.clienNews.id)
        XCTAssertTrue(defaults.bool(forKey: "favoritesSeeded"), "seededKey 가 true 로 남아 다음 인스턴스에서 재seed 안 함")
    }

    func testSeededFlagPreventsResedingAfterUserClearedAllFavorites() {
        // First boot: seeds clien-news.
        let first = FavoritesStore(defaults: defaults)
        first.toggle(.clienNews) // user removes the seeded favorite
        XCTAssertTrue(first.favoriteBoards().isEmpty)
        // Second boot: empty favorites, seededKey already set → no reseed.
        let second = FavoritesStore(defaults: defaults)
        XCTAssertTrue(second.favoriteBoards().isEmpty, "한 번 seed 된 뒤 사용자가 다 지웠으면 재seed 안 됨")
    }

    // MARK: - v3 read-back

    func testSnapshotWithStaleSearchQueryNameIsNormalizedOnRehydrate() throws {
        // A persisted snapshot might carry Clien's pre-rename `sv`
        // searchQueryName. `Board.init` runs `normalizedSearchQueryName(...)`
        // which forces Clien back to `q` regardless of what's persisted.
        let staleSnapshot = FavoriteBoardSnapshot.raw(
            id: Board.clienNews.id,
            siteRaw: "clien",
            name: "새로운 소식",
            path: "/service/board/news",
            filters: [],
            searchQueryName: "sv",  // stale
            pageQueryName: nil
        )
        let data = try JSONEncoder().encode([staleSnapshot])
        defaults.set(data, forKey: "favoriteBoards.v3")

        let store = FavoritesStore(defaults: defaults)
        let board = store.favoriteBoards().first
        XCTAssertEqual(board?.searchQueryName, "q", "stale 'sv' → 'q' 로 정규화")
    }

    func testV3OrderedArrayReadsBackInOrder() throws {
        // v3 preserves the user-edited order; assert it round-trips.
        let snapshots = [
            FavoriteBoardSnapshot(.invenMaple),
            FavoriteBoardSnapshot(.clienNews),
            FavoriteBoardSnapshot(.aagag),
        ]
        let data = try JSONEncoder().encode(snapshots)
        defaults.set(data, forKey: "favoriteBoards.v3")

        let store = FavoritesStore(defaults: defaults)
        XCTAssertEqual(
            store.favoriteBoards().map(\.id),
            [Board.invenMaple.id, Board.clienNews.id, Board.aagag.id]
        )
    }

    // MARK: - Toggle / persist

    func testToggleAddsAndRemovesAndPersists() {
        let store = FavoritesStore(defaults: defaults)
        let initialCount = store.favoriteBoards().count

        store.toggle(.invenMaple)
        XCTAssertTrue(store.isFavorite(.invenMaple))
        XCTAssertEqual(store.favoriteBoards().count, initialCount + 1)

        // Re-instantiate from persisted UserDefaults — must read back the toggle.
        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertTrue(reloaded.isFavorite(.invenMaple))

        store.toggle(.invenMaple)
        XCTAssertFalse(store.isFavorite(.invenMaple))
        let reloadedAgain = FavoritesStore(defaults: defaults)
        XCTAssertFalse(reloadedAgain.isFavorite(.invenMaple), "remove 도 forward-persist")
    }

    // MARK: - Move semantics

    func testMoveReorderMatchesSwiftUIOnMoveSemantics() throws {
        // Seed three boards in known order via v3 path.
        let snapshots = [
            FavoriteBoardSnapshot(.clienNews),
            FavoriteBoardSnapshot(.invenMaple),
            FavoriteBoardSnapshot(.aagag),
        ]
        let data = try JSONEncoder().encode(snapshots)
        defaults.set(data, forKey: "favoriteBoards.v3")
        let store = FavoritesStore(defaults: defaults)

        // SwiftUI .onMove(fromOffsets: [2], toOffset: 0) drops index 2 at the
        // top: [aagag, clien, inven]
        store.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.favoriteBoards().map(\.id), [
            Board.aagag.id, Board.clienNews.id, Board.invenMaple.id,
        ])

        // Persisted across re-init.
        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.favoriteBoards().map(\.id), [
            Board.aagag.id, Board.clienNews.id, Board.invenMaple.id,
        ])
    }

    // MARK: - merge(boards:) propagates renames

    func testMergePropagatesRenamesPreservingOrder() {
        // Persist a snapshot with an old name.
        let oldSnapshot = FavoriteBoardSnapshot.raw(
            id: "test-board",
            siteRaw: "clien",
            name: "예전 이름",
            path: "/service/board/test",
            filters: [],
            searchQueryName: nil,
            pageQueryName: "po"
        )
        let payload = try! JSONEncoder().encode([oldSnapshot])
        defaults.set(payload, forKey: "favoriteBoards.v3")
        let store = FavoritesStore(defaults: defaults)

        // Catalog now reports the same id with a new name.
        let renamed = Board(
            id: "test-board",
            site: .clien,
            name: "새 이름",
            path: "/service/board/test"
        )
        store.merge(boards: [renamed])

        let board = store.favoriteBoards().first
        XCTAssertEqual(board?.name, "새 이름")
        // Forward-persist: a fresh load must see the renamed snapshot.
        let reloaded = FavoritesStore(defaults: defaults)
        XCTAssertEqual(reloaded.favoriteBoards().first?.name, "새 이름")
    }
}

/// Builds a `FavoriteBoardSnapshot` directly from raw fields, bypassing
/// the `init(_ board:)` path. The point is to synthesize *persisted
/// payloads* that current `Board` values cannot produce — e.g. a stale
/// `searchQueryName` (Clien's pre-rename `sv`), which `Board.init` would
/// normalize away at construction. If a test only needs fields that
/// round-trip cleanly from a `Board`, prefer
/// `FavoriteBoardSnapshot(_ board:)` directly.
private extension FavoriteBoardSnapshot {
    static func raw(
        id: String,
        siteRaw: String,
        name: String,
        path: String,
        filters: [BoardFilter],
        searchQueryName: String?,
        pageQueryName: String?
    ) -> FavoriteBoardSnapshot {
        // Round-trip filters through BoardFilter.Codable so we honor whatever
        // shape the production decoder expects, instead of hand-writing the
        // JSON for `BoardFilter`.
        let filtersData = try! JSONEncoder().encode(filters)
        let json: [String: Any] = [
            "id": id,
            "siteRaw": siteRaw,
            "name": name,
            "path": path,
            "filters": try! JSONSerialization.jsonObject(with: filtersData),
            "searchQueryName": searchQueryName as Any? ?? NSNull(),
            "pageQueryName": pageQueryName as Any? ?? NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(FavoriteBoardSnapshot.self, from: data)
    }
}
