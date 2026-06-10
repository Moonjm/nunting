import XCTest
@testable import nunting

/// `BoardListSnapshotStore` — 마지막 성공 목록 1건을 디스크에 보관해
/// 콜드 스타트의 "스피너 1~3초"를 "목록 즉시 + 백그라운드 재검증"으로
/// 바꾸는 저장소. 단일 파일, 최신 1건만.
final class BoardListSnapshotStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("list-snapshot-\(UUID().uuidString).json")
    }

    func testSaveThenLoadRoundTrips() async {
        let store = BoardListSnapshotStore(fileURL: tempURL())
        let posts = [Post.fixture(id: "clien-1", title: "디스크 글")]
        await store.save(key: "clien-news|_all|", posts: posts)

        let loaded = await store.load()
        XCTAssertEqual(loaded?.key, "clien-news|_all|")
        XCTAssertEqual(loaded?.posts.count, 1)
        XCTAssertEqual(loaded?.posts.first?.title, "디스크 글")
        XCTAssertEqual(loaded?.posts.first?.id, "clien-1")
    }

    func testLoadReturnsNilWhenFileMissing() async {
        let store = BoardListSnapshotStore(fileURL: tempURL())
        let loaded = await store.load()
        XCTAssertNil(loaded)
    }

    func testCorruptFileReturnsNil() async throws {
        let url = tempURL()
        try Data("not json{{".utf8).write(to: url)
        let store = BoardListSnapshotStore(fileURL: url)
        let loaded = await store.load()
        XCTAssertNil(loaded, "손상 파일은 조용히 무시 — 콜드 패스로 폴백")
    }

    func testSaveOverwritesPreviousSnapshot() async {
        let store = BoardListSnapshotStore(fileURL: tempURL())
        await store.save(key: "a", posts: [Post.fixture(id: "1", title: "옛글")])
        await store.save(key: "b", posts: [Post.fixture(id: "2", title: "새글")])

        let loaded = await store.load()
        XCTAssertEqual(loaded?.key, "b", "최신 1건만 보관")
        XCTAssertEqual(loaded?.posts.first?.title, "새글")
    }
}
