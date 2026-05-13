import XCTest
@testable import NuntingServer

final class StoreTests: XCTestCase {
    /// 임시 디스크 파일을 만들어 Store를 열고 즉시 닫는다.
    /// SQLite 초기화 + sqlite3_close 호출 경로를 확인.
    func testOpenAndCloseFileBackedDatabase() async throws {
        let path = NSTemporaryDirectory() + "nunting-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try Store(path: path)
        await store.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// 두 번 open 후 같은 스키마를 적용해도 idempotent해야 한다.
    /// 마이그레이션이 IF NOT EXISTS 경로를 갖는지 확인.
    func testReopenDatabaseAppliesSchemaIdempotently() async throws {
        let path = NSTemporaryDirectory() + "nunting-test-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = try Store(path: path)
        await first.close()
        let second = try Store(path: path)
        await second.close()
    }

    /// upsertUser가 멱등이고, created_at가 첫 INSERT 시각으로 고정됨을 검증.
    /// 멱등 깨지면 BearerMiddleware가 매 요청마다 row를 새로 만들어버린다.
    ///
    /// `created_at`이 Int64 초 단위라 sub-second sleep은 두 timestamp가 같은
    /// 초로 떨어져 회귀(예: `ON CONFLICT DO UPDATE SET created_at = excluded...`)를
    /// 가린다. 1.1초로 second boundary를 넘긴다.
    func testUpsertUserIsIdempotent() async throws {
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        let uuid = "nnt_test-uuid"
        try await store.upsertUser(uuid: uuid)
        let createdAt1 = try await store.createdAt(uuid: uuid)
        try await Task.sleep(for: .milliseconds(1100))
        try await store.upsertUser(uuid: uuid)
        let createdAt2 = try await store.createdAt(uuid: uuid)
        XCTAssertEqual(createdAt1, createdAt2, "upsert가 created_at을 덮어쓰면 안 됨")
    }

    /// setPushToken으로 NULL과 string 양쪽으로 토글 가능해야 함.
    /// v1에서 iOS가 알림 권한 회수했을 때 NULL을 PUT한다.
    func testSetPushTokenCanRoundTripNilAndValue() async throws {
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        let uuid = "nnt_x"
        try await store.upsertUser(uuid: uuid)
        // XCTAssert* 는 autoclosure라 안에 `await`를 못 넣는다 — 먼저 받아둔다.
        let t0 = try await store.pushToken(uuid: uuid)
        XCTAssertNil(t0)
        try await store.setPushToken(uuid: uuid, token: "aabbcc")
        let t1 = try await store.pushToken(uuid: uuid)
        XCTAssertEqual(t1, "aabbcc")
        try await store.setPushToken(uuid: uuid, token: nil)
        let t2 = try await store.pushToken(uuid: uuid)
        XCTAssertNil(t2)
    }

    /// 정규화 계약을 pin. trim + lowercase.
    /// 라우트 핸들러가 들어오는 키워드 입력 시 같은 normalizer를 거치고,
    /// 폴러도 같은 normalizer를 거쳐서 매칭한다. 어긋나면 매칭 0건이 됨.
    func testNormalizedKeywordTrimsAndLowercases() {
        XCTAssertEqual(Store.normalizedKeyword("  Galaxy S25  "), "galaxy s25")
        XCTAssertEqual(Store.normalizedKeyword("갤럭시"), "갤럭시")
        XCTAssertEqual(Store.normalizedKeyword(" RTX5090\n"), "rtx5090")
    }

    func testAddAndListKeywordsForUser() async throws {
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.addKeyword(uuid: "nnt_a", keyword: "galaxy")
        try await store.addKeyword(uuid: "nnt_a", keyword: "rtx5090")
        let listed = try await store.listKeywords(uuid: "nnt_a")
        XCTAssertEqual(Set(listed), ["galaxy", "rtx5090"])
    }

    /// (uuid, keyword) PK가 중복 INSERT를 거부하지 않고 멱등이 되는지.
    /// 스펙: "중복은 멱등(이미 있어도 201)".
    func testAddKeywordIsIdempotent() async throws {
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.addKeyword(uuid: "nnt_a", keyword: "갤럭시")
        try await store.addKeyword(uuid: "nnt_a", keyword: "갤럭시")
        let listed = try await store.listKeywords(uuid: "nnt_a")
        XCTAssertEqual(listed, ["갤럭시"])
    }

    func testRemoveKeywordIsIdempotent() async throws {
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.addKeyword(uuid: "nnt_a", keyword: "galaxy")
        try await store.removeKeyword(uuid: "nnt_a", keyword: "galaxy")
        let emptyAfterFirst = try await store.listKeywords(uuid: "nnt_a")
        XCTAssertTrue(emptyAfterFirst.isEmpty)
        // 두 번 지워도 throw 없어야 함
        try await store.removeKeyword(uuid: "nnt_a", keyword: "galaxy")
    }

    /// 키워드는 사용자 격리. 다른 user의 키워드가 섞이면 안 됨.
    func testKeywordsScopedPerUser() async throws {
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.upsertUser(uuid: "nnt_b")
        try await store.addKeyword(uuid: "nnt_a", keyword: "galaxy")
        try await store.addKeyword(uuid: "nnt_b", keyword: "rtx")
        let a = try await store.listKeywords(uuid: "nnt_a")
        let b = try await store.listKeywords(uuid: "nnt_b")
        XCTAssertEqual(a, ["galaxy"])
        XCTAssertEqual(b, ["rtx"])
    }
}
