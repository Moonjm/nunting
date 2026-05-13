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
}
