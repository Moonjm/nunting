import XCTest
@testable import nunting

/// Persistence + migration tests for `FavoritesStore`.
///
/// Each test uses an isolated `UserDefaults(suiteName:)` so cases don't
/// leak state into each other. The store's constructor already accepts
/// an injected `UserDefaults`, which is the only seam needed to keep
/// tests hermetic.
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

    // MARK: - v1 → v3 migration

    func testV1IDSetMigratesToV3Snapshots() throws {
        // v1 stored a Set<String> of board IDs under "favoriteBoardIDs".
        let ids: Set<String> = [Board.clienNews.id, Board.invenMaple.id]
        let data = try JSONEncoder().encode(ids)
        defaults.set(data, forKey: "favoriteBoardIDs")

        let store = FavoritesStore(defaults: defaults)
        let boardIDs = store.favoriteBoards().map(\.id).sorted()
        XCTAssertEqual(boardIDs, [Board.clienNews.id, Board.invenMaple.id].sorted())
        // Persisted forward as v3.
        XCTAssertNotNil(defaults.data(forKey: "favoriteBoards.v3"))
    }

    // MARK: - v2 → v3 migration

    func testV2DictMigratesToV3SortedArray() throws {
        // v2 stored a dict keyed by board ID. Migration sorts by snapshot name
        // because the dict has no inherent ordering.
        let news = FavoriteBoardSnapshot(.clienNews)
        let inven = FavoriteBoardSnapshot(.invenMaple)
        let dict: [String: FavoriteBoardSnapshot] = [news.id: news, inven.id: inven]
        let data = try JSONEncoder().encode(dict)
        defaults.set(data, forKey: "favoriteBoards.v2")

        let store = FavoritesStore(defaults: defaults)
        let boards = store.favoriteBoards()
        XCTAssertEqual(boards.count, 2)
        // 메이플 자유게시판 (ㅁ) < 새로운 소식 (ㅅ)
        XCTAssertEqual(boards.map(\.name), ["메이플 자유게시판", "새로운 소식"])
        XCTAssertNotNil(defaults.data(forKey: "favoriteBoards.v3"), "v3 로 forward-persist")
    }

    func testV2SnapshotWithStaleSearchQueryNameIsNormalizedOnRehydrate() throws {
        // v2 snapshot might carry Clien's pre-rename `sv` searchQueryName.
        // `Board.init` runs `normalizedSearchQueryName(...)` which forces
        // Clien back to `q` regardless of what's persisted.
        let staleSnapshot = FavoriteBoardSnapshot.legacy(
            id: Board.clienNews.id,
            siteRaw: "clien",
            name: "새로운 소식",
            path: "/service/board/news",
            filters: [],
            searchQueryName: "sv",  // stale
            pageQueryName: nil
        )
        let dict: [String: FavoriteBoardSnapshot] = [staleSnapshot.id: staleSnapshot]
        let data = try JSONEncoder().encode(dict)
        defaults.set(data, forKey: "favoriteBoards.v2")

        let store = FavoritesStore(defaults: defaults)
        let board = store.favoriteBoards().first
        XCTAssertEqual(board?.searchQueryName, "q", "stale 'sv' → 'q' 로 정규화")
    }

    // MARK: - v3 read-back

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
        let oldSnapshot = FavoriteBoardSnapshot.legacy(
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

/// Helper that builds a `FavoriteBoardSnapshot` directly from raw fields
/// — bypasses the `init(_ board:)` path so tests can synthesize legacy
/// payloads (stale `searchQueryName`, missing fields) that wouldn't be
/// producible from a current `Board` value.
private extension FavoriteBoardSnapshot {
    static func legacy(
        id: String,
        siteRaw: String,
        name: String,
        path: String,
        filters: [BoardFilter]?,
        searchQueryName: String?,
        pageQueryName: String?
    ) -> FavoriteBoardSnapshot {
        let json: [String: Any] = [
            "id": id,
            "siteRaw": siteRaw,
            "name": name,
            "path": path,
            "filters": filters.map { _ in [] as [Any] } ?? [] as Any,
            "searchQueryName": searchQueryName as Any? ?? NSNull(),
            "pageQueryName": pageQueryName as Any? ?? NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(FavoriteBoardSnapshot.self, from: data)
    }
}
