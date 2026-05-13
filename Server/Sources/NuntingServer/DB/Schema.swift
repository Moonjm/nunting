import CSQLite

enum Schema {
    /// 스펙 문서 §데이터 모델 그대로. `IF NOT EXISTS`로 재실행 안전.
    static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS users (
            uuid       TEXT PRIMARY KEY,
            push_token TEXT,
            created_at INTEGER NOT NULL
        );
        """,
        """
        CREATE TABLE IF NOT EXISTS keyword_subs (
            uuid    TEXT NOT NULL,
            keyword TEXT NOT NULL,
            PRIMARY KEY (uuid, keyword),
            FOREIGN KEY (uuid) REFERENCES users(uuid) ON DELETE CASCADE
        );
        """,
        """
        CREATE INDEX IF NOT EXISTS idx_users_with_token
            ON users(uuid)
            WHERE push_token IS NOT NULL;
        """,
        // FK는 SQLite에서 connection별로 활성화해야 함. Store.init이 PRAGMA로
        // 켜준다는 가정 위에 여기는 schema만 둔다.
    ]

    static func apply(to db: OpaquePointer) throws {
        for sql in statements {
            var err: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &err)
            if rc != SQLITE_OK {
                let message = err.map { String(cString: $0) } ?? "schema apply failed (rc=\(rc))"
                sqlite3_free(err)
                throw StoreError.sqlite(rc: rc, message: message)
            }
        }
    }
}
