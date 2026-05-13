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
    func testUpsertUserIsIdempotent() async throws {
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        let uuid = "nnt_test-uuid"
        try await store.upsertUser(uuid: uuid)
        let createdAt1 = try await store.createdAt(uuid: uuid)
        try await Task.sleep(for: .milliseconds(20))
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
}
