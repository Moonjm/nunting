import CSQLite
import Foundation

enum StoreError: Error, CustomStringConvertible {
    case sqlite(rc: Int32, message: String)
    case openFailed(path: String, rc: Int32)

    var description: String {
        switch self {
        case .sqlite(let rc, let message):
            return "sqlite error rc=\(rc): \(message)"
        case .openFailed(let path, let rc):
            return "sqlite open failed (path=\(path), rc=\(rc))"
        }
    }
}

/// 모든 SQLite 작업의 단일 진입점. actor로 직렬화해 multi-threaded SQLite
/// build 의존을 피하고 prepared statement 재사용을 단순화한다.
public actor Store {
    private var db: OpaquePointer?

    /// `path == ":memory:"`면 in-memory DB. 테스트는 이걸 쓴다.
    public init(path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open(path, &handle)
        guard rc == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw StoreError.openFailed(path: path, rc: rc)
        }
        // FK 강제. keyword_subs.uuid → users.uuid ON DELETE CASCADE가
        // 의미 있으려면 connection별로 켜야 한다.
        sqlite3_exec(handle, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        do {
            try Schema.apply(to: handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        self.db = handle
    }

    public func close() {
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    // NOTE: deinit fallback close는 Swift 6 strict concurrency 하에서
    // `isolated deinit`(macOS 15.4+)이 필요해 의도적으로 두지 않는다.
    // 호출자는 사용 종료 시 `await close()`를 반드시 호출한다 — 테스트가
    // 이 contract를 강제한다.
}
