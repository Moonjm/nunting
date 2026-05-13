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

extension Store {
    /// SQLITE_TRANSIENT — string을 sqlite가 자체 복사하게 강제.
    /// statement가 step되기 전에 Swift 측 buffer가 사라질 수 있으므로 STATIC 금지.
    private static let TRANSIENT = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    public func upsertUser(uuid: String) throws {
        let sql = """
        INSERT INTO users (uuid, push_token, created_at)
        VALUES (?, NULL, ?)
        ON CONFLICT(uuid) DO NOTHING;
        """
        try execute(sql) { stmt in
            sqlite3_bind_text(stmt, 1, uuid, -1, Self.TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970))
        }
    }

    public func setPushToken(uuid: String, token: String?) throws {
        let sql = "UPDATE users SET push_token = ? WHERE uuid = ?;"
        try execute(sql) { stmt in
            if let token {
                sqlite3_bind_text(stmt, 1, token, -1, Self.TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, uuid, -1, Self.TRANSIENT)
        }
    }

    func createdAt(uuid: String) throws -> Int64? {
        try queryOne("SELECT created_at FROM users WHERE uuid = ?;", bind: { stmt in
            sqlite3_bind_text(stmt, 1, uuid, -1, Self.TRANSIENT)
        }, read: { stmt in
            sqlite3_column_int64(stmt, 0)
        })
    }

    func pushToken(uuid: String) throws -> String? {
        try queryOne("SELECT push_token FROM users WHERE uuid = ?;", bind: { stmt in
            sqlite3_bind_text(stmt, 1, uuid, -1, Self.TRANSIENT)
        }, read: { stmt -> String? in
            guard let cstr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: cstr)
        }) ?? nil
    }

    // MARK: - prepare/step helpers

    /// INSERT/UPDATE/DELETE 등 결과 row가 없는 statement용.
    private func execute(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let db else { throw StoreError.sqlite(rc: 0, message: "store closed") }
        var stmt: OpaquePointer?
        let pRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard pRC == SQLITE_OK, let stmt else {
            throw StoreError.sqlite(rc: pRC, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            throw StoreError.sqlite(rc: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }

    /// 단일 row select. row 없으면 nil 반환.
    private func queryOne<T>(
        _ sql: String,
        bind: (OpaquePointer) -> Void,
        read: (OpaquePointer) -> T
    ) throws -> T? {
        guard let db else { throw StoreError.sqlite(rc: 0, message: "store closed") }
        var stmt: OpaquePointer?
        let pRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard pRC == SQLITE_OK, let stmt else {
            throw StoreError.sqlite(rc: pRC, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return read(stmt)
        case SQLITE_DONE: return nil
        default: throw StoreError.sqlite(rc: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }
}
