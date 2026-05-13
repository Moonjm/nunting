# Plan 2 — NuntingServer Minimum (PR B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hummingbird 기반 라즈베리파이 서버의 HTTP/저장소/인증 골격을 SPM 실행 패키지로 신설한다. 키워드 CRUD와 푸시 토큰 등록 4개 엔드포인트가 SQLite와 함께 동작하고, 폴러/APNs 없이 macOS에서 `curl`로 전체 CRUD를 확인할 수 있는 상태로 마감한다.

**Architecture:**
- Monorepo 루트에 신규 `Server/` SPM 실행 패키지를 두고 `dependencies: [.package(path: "../Shared")]`로 NuntingCore를 import 가능하게만 연결한다(이번 PR에선 직접 import는 폴러에서 PR C에 시작).
- Hummingbird 2.x `Router` + 커스텀 `RequestContext`로 BearerMiddleware가 토큰을 검증하고 `users.uuid`를 컨텍스트에 싣는다.
- SQLite는 raw `sqlite3` C API + 얇은 Swift 래퍼 `Store`로 다룬다(외부 ORM 의존성 0). macOS/Linux 양쪽 컴파일이 가능하도록 SPM `systemLibrary` 타겟 `CSQLite`로 헤더만 노출한다.

**Tech Stack:**
- Swift 6.0 toolchain, `swift-tools-version: 6.0`
- Hummingbird `2.0.0+`
- Swift Standard Library + Foundation
- `CSQLite` system module (macOS 시스템 sqlite3 / Linux `libsqlite3-dev`)
- XCTest (기존 repo와 일관)

---

## File Structure

```
Server/
├── Package.swift                                       # 신규
├── Sources/
│   ├── CSQLite/
│   │   ├── module.modulemap                            # 신규
│   │   └── shim.h                                      # 신규
│   └── NuntingServer/
│       ├── App.swift                                   # 신규: buildApp(store:) → Application
│       ├── main.swift                                  # 신규: env 읽기 + buildApp + runService
│       ├── Auth/
│       │   ├── UserRequestContext.swift                # 신규: 커스텀 RequestContext
│       │   └── BearerMiddleware.swift                  # 신규
│       ├── DB/
│       │   ├── Schema.swift                            # 신규: CREATE TABLE SQL 상수 + 마이그레이션
│       │   └── Store.swift                             # 신규: open/close + users/keywords CRUD
│       └── Routes/
│           ├── PushTokenRoute.swift                    # 신규: PUT /me/push-token
│           └── KeywordRoutes.swift                     # 신규: GET/POST/DELETE /me/keywords[/{k}]
└── Tests/
    └── NuntingServerTests/
        ├── StoreTests.swift                            # 신규: users + keywords CRUD
        ├── BearerMiddlewareTests.swift                 # 신규: 401 케이스 + 컨텍스트 주입
        ├── PushTokenRouteTests.swift                   # 신규
        └── KeywordRoutesTests.swift                    # 신규
```

각 파일의 책임:
- `Package.swift`: 의존성/타겟 선언, swift-tools 6.0, NonisolatedNonsendingByDefault upcoming feature.
- `CSQLite/`: `sqlite3.h`를 단일 clang 모듈로 노출(macOS: 시스템, Linux: `pkgConfig`).
- `App.swift`: `buildApp(store:)` 함수 한 개. main.swift와 테스트 모두 이걸 호출해 Application을 만든다(테스트가 in-memory store로 주입).
- `main.swift`: 진입점. 환경변수에서 DB 경로/포트 읽고 `buildApp` 후 `runService()`.
- `UserRequestContext.swift`: `RequestContext` 채택 + `userUUID: String?` 필드.
- `BearerMiddleware.swift`: `MiddlewareProtocol`. `Authorization: Bearer nnt_<uuid>` 파싱, prefix 검사, `Store.upsertUser(uuid:)`, 컨텍스트에 uuid 주입.
- `Schema.swift`: `CREATE TABLE` SQL 상수 + `apply(_:)` 멱등 마이그레이션.
- `Store.swift`: `Store` actor. 메서드: `init(path:)`, `close()`, `upsertUser(uuid:)`, `setPushToken(uuid:token:)`, `addKeyword(uuid:keyword:)`, `listKeywords(uuid:)`, `removeKeyword(uuid:keyword:)`, `normalizedKeyword(_:)` static.
- `PushTokenRoute.swift`: 라우트 1개 + 요청 모델.
- `KeywordRoutes.swift`: 라우트 3개 + 응답 모델.

각 task는 한 파일(또는 한 쌍의 소스+테스트)에 집중한다.

---

## Task 1: 패키지 골격 + CSQLite 브리지 + /health 스모크

**Files:**
- Create: `Server/Package.swift`
- Create: `Server/Sources/CSQLite/module.modulemap`
- Create: `Server/Sources/CSQLite/shim.h`
- Create: `Server/Sources/NuntingServer/App.swift`
- Create: `Server/Sources/NuntingServer/main.swift`

- [ ] **Step 1: `Server/Package.swift` 작성**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NuntingServer",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "NuntingServer", targets: ["NuntingServer"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [
                .brew(["sqlite3"]),
                .apt(["libsqlite3-dev"]),
            ]
        ),
        .executableTarget(
            name: "NuntingServer",
            dependencies: [
                "CSQLite",
                .product(name: "NuntingCore", package: "Shared"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/NuntingServer",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .testTarget(
            name: "NuntingServerTests",
            dependencies: [
                "NuntingServer",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            path: "Tests/NuntingServerTests",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
    ]
)
```

- [ ] **Step 2: CSQLite 모듈맵 + 헤더 작성**

`Server/Sources/CSQLite/module.modulemap`:
```
module CSQLite [system] {
    header "shim.h"
    link "sqlite3"
    export *
}
```

`Server/Sources/CSQLite/shim.h`:
```c
#ifndef NUNTING_CSQLITE_SHIM_H
#define NUNTING_CSQLITE_SHIM_H

#include <sqlite3.h>

#endif
```

- [ ] **Step 3: `App.swift` — buildApp 스텁**

`Server/Sources/NuntingServer/App.swift`:
```swift
import Hummingbird

/// Build the HTTP application.
///
/// 테스트는 in-memory store로 이걸 호출하고, main.swift는 디스크 path를
/// 가진 store로 호출한다. 라우트는 task 5~6에서 채워진다.
public func buildApp() -> some ApplicationProtocol {
    let router = Router()
    router.get("/health") { _, _ in "ok" }
    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 8080))
    )
}
```

- [ ] **Step 4: `main.swift` 작성**

`Server/Sources/NuntingServer/main.swift`:
```swift
import Hummingbird

let app = buildApp()
try await app.runService()
```

- [ ] **Step 5: 빌드 + 스모크 검증**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift build
```

Expected: `Build complete!`

서버 띄우고 다른 터미널에서:
```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift run NuntingServer &
SERVER_PID=$!
sleep 2
curl -s http://127.0.0.1:8080/health
kill $SERVER_PID
```

Expected: `ok`

- [ ] **Step 6: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Server/Package.swift Server/Sources/CSQLite/ Server/Sources/NuntingServer/App.swift Server/Sources/NuntingServer/main.swift
git commit -m "feat(server): NuntingServer SPM 패키지 골격 + /health 스모크"
```

---

## Task 2: Store 골격 — open/close + Schema

**Files:**
- Create: `Server/Sources/NuntingServer/DB/Schema.swift`
- Create: `Server/Sources/NuntingServer/DB/Store.swift`
- Create: `Server/Tests/NuntingServerTests/StoreTests.swift`

- [ ] **Step 1: 실패 테스트부터 — 빈 DB 열고 닫기**

`Server/Tests/NuntingServerTests/StoreTests.swift`:
```swift
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
```

- [ ] **Step 2: 실패 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift test --filter StoreTests
```

Expected: `error: cannot find 'Store' in scope`

- [ ] **Step 3: Schema 작성**

`Server/Sources/NuntingServer/DB/Schema.swift`:
```swift
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
```

- [ ] **Step 4: Store 작성 — open/close만**

`Server/Sources/NuntingServer/DB/Store.swift`:
```swift
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

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift test --filter StoreTests
```

Expected: 2 tests passed.

- [ ] **Step 6: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Server/Sources/NuntingServer/DB/ Server/Tests/NuntingServerTests/StoreTests.swift
git commit -m "feat(server): Store 골격 + 스키마 마이그레이션"
```

---

## Task 3: Store.users — upsert + setPushToken

**Files:**
- Modify: `Server/Sources/NuntingServer/DB/Store.swift`
- Modify: `Server/Tests/NuntingServerTests/StoreTests.swift`

- [ ] **Step 1: 실패 테스트 추가**

`StoreTests.swift`에 메서드 추가:
```swift
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
    XCTAssertNil(try await store.pushToken(uuid: uuid))
    try await store.setPushToken(uuid: uuid, token: "aabbcc")
    XCTAssertEqual(try await store.pushToken(uuid: uuid), "aabbcc")
    try await store.setPushToken(uuid: uuid, token: nil)
    XCTAssertNil(try await store.pushToken(uuid: uuid))
}
```

`StoreTests.swift` 상단에 헬퍼 extension은 두지 말고 `Store`에 internal 메서드로 `createdAt(uuid:)`, `pushToken(uuid:)`를 추가(테스트 전용 readers; 프로덕션 코드도 향후 폴러가 사용).

- [ ] **Step 2: 실패 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift test --filter StoreTests
```

Expected: 2 new tests FAIL with "value of type 'Store' has no member 'upsertUser'" 등.

- [ ] **Step 3: Store에 메서드 추가**

`Store.swift`에 추가:
```swift
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
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift test --filter StoreTests
```

Expected: 4 tests passed.

- [ ] **Step 5: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Server/Sources/NuntingServer/DB/Store.swift Server/Tests/NuntingServerTests/StoreTests.swift
git commit -m "feat(server): Store.upsertUser + setPushToken"
```

---

## Task 4: Store.keywords — add/list/remove + 정규화

**Files:**
- Modify: `Server/Sources/NuntingServer/DB/Store.swift`
- Modify: `Server/Tests/NuntingServerTests/StoreTests.swift`

- [ ] **Step 1: 실패 테스트 추가**

`StoreTests.swift`에 추가:
```swift
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
    XCTAssertEqual(try await store.listKeywords(uuid: "nnt_a"), ["갤럭시"])
}

func testRemoveKeywordIsIdempotent() async throws {
    let store = try Store(path: ":memory:")
    defer { Task { await store.close() } }
    try await store.upsertUser(uuid: "nnt_a")
    try await store.addKeyword(uuid: "nnt_a", keyword: "galaxy")
    try await store.removeKeyword(uuid: "nnt_a", keyword: "galaxy")
    XCTAssertTrue(try await store.listKeywords(uuid: "nnt_a").isEmpty)
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
    XCTAssertEqual(try await store.listKeywords(uuid: "nnt_a"), ["galaxy"])
    XCTAssertEqual(try await store.listKeywords(uuid: "nnt_b"), ["rtx"])
}
```

- [ ] **Step 2: 실패 확인**

```bash
swift test --filter StoreTests
```

Expected: 5 new tests FAIL.

- [ ] **Step 3: Store에 메서드 추가**

`Store.swift`에 추가:
```swift
extension Store {
    /// 라우트 핸들러 + 폴러가 매칭 전에 통과시켜야 하는 단일 정규화.
    /// 한글은 lowercased가 사실상 no-op이지만 영문/숫자 키워드(m4, RTX5090)와
    /// 일관 동작을 보장.
    public static func normalizedKeyword(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// 호출자 책임: keyword는 normalizedKeyword()를 이미 통과한 상태.
    /// (라우트 layer에서 길이/빈 문자열 검증 후 normalize → 저장 호출)
    public func addKeyword(uuid: String, keyword: String) throws {
        let sql = """
        INSERT INTO keyword_subs (uuid, keyword) VALUES (?, ?)
        ON CONFLICT(uuid, keyword) DO NOTHING;
        """
        try execute(sql) { stmt in
            sqlite3_bind_text(stmt, 1, uuid, -1, Self.TRANSIENT)
            sqlite3_bind_text(stmt, 2, keyword, -1, Self.TRANSIENT)
        }
    }

    public func removeKeyword(uuid: String, keyword: String) throws {
        let sql = "DELETE FROM keyword_subs WHERE uuid = ? AND keyword = ?;"
        try execute(sql) { stmt in
            sqlite3_bind_text(stmt, 1, uuid, -1, Self.TRANSIENT)
            sqlite3_bind_text(stmt, 2, keyword, -1, Self.TRANSIENT)
        }
    }

    public func listKeywords(uuid: String) throws -> [String] {
        guard let db else { throw StoreError.sqlite(rc: 0, message: "store closed") }
        let sql = "SELECT keyword FROM keyword_subs WHERE uuid = ? ORDER BY keyword;"
        var stmt: OpaquePointer?
        let pRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard pRC == SQLITE_OK, let stmt else {
            throw StoreError.sqlite(rc: pRC, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, uuid, -1, Self.TRANSIENT)
        var out: [String] = []
        while true {
            let rc = sqlite3_step(stmt)
            switch rc {
            case SQLITE_ROW:
                if let cstr = sqlite3_column_text(stmt, 0) {
                    out.append(String(cString: cstr))
                }
            case SQLITE_DONE:
                return out
            default:
                throw StoreError.sqlite(rc: rc, message: String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
swift test --filter StoreTests
```

Expected: 9 tests passed.

- [ ] **Step 5: 커밋**

```bash
git add Server/Sources/NuntingServer/DB/Store.swift Server/Tests/NuntingServerTests/StoreTests.swift
git commit -m "feat(server): Store 키워드 CRUD + 정규화"
```

---

## Task 5: UserRequestContext + BearerMiddleware

**Files:**
- Create: `Server/Sources/NuntingServer/Auth/UserRequestContext.swift`
- Create: `Server/Sources/NuntingServer/Auth/BearerMiddleware.swift`
- Create: `Server/Tests/NuntingServerTests/BearerMiddlewareTests.swift`
- Modify: `Server/Sources/NuntingServer/App.swift`

- [ ] **Step 1: 실패 테스트 — Bearer 헤더 검증 + 컨텍스트 주입**

`BearerMiddlewareTests.swift`:
```swift
import XCTest
import Hummingbird
import HummingbirdTesting
@testable import NuntingServer

final class BearerMiddlewareTests: XCTestCase {
    /// 헤더가 아예 없으면 401.
    func testMissingAuthorizationHeaderReturns401() async throws {
        let store = try Store(path: ":memory:")
        let app = buildApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(uri: "/me/_echo", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
        await store.close()
    }

    /// prefix가 "nnt_"가 아니면 401. 봇이 추측한 임의 Bearer 차단.
    func testBearerWithoutNntPrefixReturns401() async throws {
        let store = try Store(path: ":memory:")
        let app = buildApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/_echo",
                method: .get,
                headers: [.authorization: "Bearer abcdef"]
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
        await store.close()
    }

    /// 정상 토큰이면 200 + 응답 body에 uuid를 그대로 반환(echo).
    /// 동시에 users row가 upsert됐는지도 검증.
    func testValidBearerUpsertsUserAndExposesUUIDInContext() async throws {
        let store = try Store(path: ":memory:")
        let app = buildApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/_echo",
                method: .get,
                headers: [.authorization: "Bearer nnt_alice"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "nnt_alice")
            }
        }
        let createdAt = try await store.createdAt(uuid: "nnt_alice")
        XCTAssertNotNil(createdAt, "Bearer 통과 시 users.uuid가 upsert돼야 함")
        await store.close()
    }
}
```

- [ ] **Step 2: 실패 확인**

```bash
swift test --filter BearerMiddlewareTests
```

Expected: `cannot find 'buildApp' ... with store argument`, BearerMiddleware 미존재.

- [ ] **Step 3: UserRequestContext 작성**

`Server/Sources/NuntingServer/Auth/UserRequestContext.swift`:
```swift
import Hummingbird

/// BearerMiddleware가 검증 통과 후 uuid를 싣고, 라우트 핸들러가 읽는다.
/// `userUUID`가 nil인 경로에 라우트 도달하면 미들웨어가 빠진 것 = 라우터
/// 설정 버그. 라우트 핸들러는 force-unwrap이 아닌 require()로 401을 던진다.
struct UserRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    var userUUID: String?

    init(source: Source) {
        self.coreContext = .init(source: source)
        self.userUUID = nil
    }
}

extension UserRequestContext {
    func requireUUID() throws -> String {
        guard let userUUID else {
            throw HTTPError(.unauthorized)
        }
        return userUUID
    }
}
```

- [ ] **Step 4: BearerMiddleware 작성**

`Server/Sources/NuntingServer/Auth/BearerMiddleware.swift`:
```swift
import Hummingbird

/// `Authorization: Bearer nnt_<uuid>` 검증 + users.upsert.
///
/// 스펙 §인증 정확히 그대로:
///  - 헤더 없거나 prefix가 "nnt_"가 아니면 401.
///  - 통과한 토큰을 그대로 users.uuid로 upsert.
///  - users.uuid를 context에 싣고 next.
struct BearerMiddleware: MiddlewareProtocol {
    typealias Context = UserRequestContext

    let store: Store
    private static let bearerPrefix = "Bearer "
    private static let uuidPrefix = "nnt_"

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let header = request.headers[.authorization],
              header.hasPrefix(Self.bearerPrefix)
        else {
            throw HTTPError(.unauthorized)
        }
        let token = String(header.dropFirst(Self.bearerPrefix.count))
        guard token.hasPrefix(Self.uuidPrefix), token.count > Self.uuidPrefix.count else {
            throw HTTPError(.unauthorized)
        }
        try await store.upsertUser(uuid: token)
        var context = context
        context.userUUID = token
        return try await next(request, context)
    }
}
```

- [ ] **Step 5: App.swift 수정 — store 주입 + middleware 마운트**

`Server/Sources/NuntingServer/App.swift` 전체 교체:
```swift
import Hummingbird

/// 테스트는 `:memory:` Store를, main.swift는 디스크 Store를 주입한다.
/// 라우트는 후속 task에서 채워진다. 지금은 /health(인증 없이)와 /me/_echo
/// (인증 통과 후 uuid echo) 두 개만 둔다.
public func buildApp(store: Store) -> some ApplicationProtocol {
    let router = Router(context: UserRequestContext.self)

    router.get("/health") { _, _ in "ok" }

    let authed = router.group("/me")
        .add(middleware: BearerMiddleware(store: store))
    authed.get("/_echo") { _, context in
        try context.requireUUID()
    }

    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 8080))
    )
}
```

- [ ] **Step 6: main.swift 수정 — Store 생성**

`Server/Sources/NuntingServer/main.swift`:
```swift
import Hummingbird
import Foundation

let dbPath = ProcessInfo.processInfo.environment["NUNTING_DB_PATH"]
    ?? "/var/lib/nunting/state.db"
let store = try Store(path: dbPath)
let app = buildApp(store: store)
try await app.runService()
```

- [ ] **Step 7: 테스트 통과 확인**

```bash
swift test --filter BearerMiddlewareTests
```

Expected: 3 tests passed.

- [ ] **Step 8: 커밋**

```bash
git add Server/Sources/NuntingServer/Auth/ Server/Sources/NuntingServer/App.swift Server/Sources/NuntingServer/main.swift Server/Tests/NuntingServerTests/BearerMiddlewareTests.swift
git commit -m "feat(server): BearerMiddleware + UserRequestContext"
```

---

## Task 6: PUT /me/push-token

**Files:**
- Create: `Server/Sources/NuntingServer/Routes/PushTokenRoute.swift`
- Create: `Server/Tests/NuntingServerTests/PushTokenRouteTests.swift`
- Modify: `Server/Sources/NuntingServer/App.swift`

- [ ] **Step 1: 실패 테스트**

`PushTokenRouteTests.swift`:
```swift
import XCTest
import Hummingbird
import HummingbirdTesting
@testable import NuntingServer

final class PushTokenRouteTests: XCTestCase {
    func testPutPushTokenPersists() async throws {
        let store = try Store(path: ":memory:")
        let app = buildApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/push-token",
                method: .put,
                headers: [
                    .authorization: "Bearer nnt_alice",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"token":"aabbccdd"}"#)
            ) { response in
                XCTAssertEqual(response.status, .noContent)
            }
        }
        XCTAssertEqual(try await store.pushToken(uuid: "nnt_alice"), "aabbccdd")
        await store.close()
    }

    /// `"token": null` 또는 키 자체가 누락이면 NULL 저장(권한 회수 신호).
    func testPutPushTokenWithNullClearsToken() async throws {
        let store = try Store(path: ":memory:")
        try await store.upsertUser(uuid: "nnt_alice")
        try await store.setPushToken(uuid: "nnt_alice", token: "existing")
        let app = buildApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/push-token",
                method: .put,
                headers: [
                    .authorization: "Bearer nnt_alice",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"token":null}"#)
            ) { response in
                XCTAssertEqual(response.status, .noContent)
            }
        }
        XCTAssertNil(try await store.pushToken(uuid: "nnt_alice"))
        await store.close()
    }

    func testPutPushTokenRequiresAuth() async throws {
        let store = try Store(path: ":memory:")
        let app = buildApp(store: store)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/push-token",
                method: .put,
                headers: [.contentType: "application/json"],
                body: ByteBuffer(string: #"{"token":"x"}"#)
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
        await store.close()
    }
}
```

- [ ] **Step 2: 실패 확인**

```bash
swift test --filter PushTokenRouteTests
```

Expected: 404 또는 라우트 미존재 fail.

- [ ] **Step 3: 라우트 작성**

`Server/Sources/NuntingServer/Routes/PushTokenRoute.swift`:
```swift
import Hummingbird

struct PushTokenRoutes {
    let store: Store

    struct PutTokenRequest: Decodable {
        let token: String?
    }

    func add(to router: RouterGroup<UserRequestContext>) {
        router.put("/push-token") { request, context -> HTTPResponse.Status in
            let body = try await request.decode(as: PutTokenRequest.self, context: context)
            let uuid = try context.requireUUID()
            try await store.setPushToken(uuid: uuid, token: body.token)
            return .noContent
        }
    }
}
```

- [ ] **Step 4: App.swift에 라우트 마운트**

`App.swift`의 `authed` 그룹에 추가:
```swift
let authed = router.group("/me")
    .add(middleware: BearerMiddleware(store: store))
authed.get("/_echo") { _, context in
    try context.requireUUID()
}
PushTokenRoutes(store: store).add(to: authed)
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
swift test --filter PushTokenRouteTests
```

Expected: 3 tests passed.

- [ ] **Step 6: 커밋**

```bash
git add Server/Sources/NuntingServer/Routes/PushTokenRoute.swift Server/Sources/NuntingServer/App.swift Server/Tests/NuntingServerTests/PushTokenRouteTests.swift
git commit -m "feat(server): PUT /me/push-token"
```

---

## Task 7: GET/POST/DELETE /me/keywords

**Files:**
- Create: `Server/Sources/NuntingServer/Routes/KeywordRoutes.swift`
- Create: `Server/Tests/NuntingServerTests/KeywordRoutesTests.swift`
- Modify: `Server/Sources/NuntingServer/App.swift`

- [ ] **Step 1: 실패 테스트**

`KeywordRoutesTests.swift`:
```swift
import XCTest
import Hummingbird
import HummingbirdTesting
@testable import NuntingServer

final class KeywordRoutesTests: XCTestCase {
    private func makeApp() throws -> (Store, some ApplicationProtocol) {
        let store = try Store(path: ":memory:")
        return (store, buildApp(store: store))
    }

    func testListReturnsEmptyArrayForNewUser() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/keywords",
                method: .get,
                headers: [.authorization: "Bearer nnt_alice"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "[]")
            }
        }
    }

    /// POST는 정규화 결과를 echo. 201 + normalized body.
    func testPostNormalizesAndReturns201() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/keywords",
                method: .post,
                headers: [
                    .authorization: "Bearer nnt_alice",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"keyword":"  Galaxy S25  "}"#)
            ) { response in
                XCTAssertEqual(response.status, .created)
                XCTAssertEqual(String(buffer: response.body), #""galaxy s25""#)
            }
        }
        XCTAssertEqual(try await store.listKeywords(uuid: "nnt_alice"), ["galaxy s25"])
    }

    func testPostEmptyKeywordReturns400() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/keywords",
                method: .post,
                headers: [
                    .authorization: "Bearer nnt_alice",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"keyword":"   "}"#)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    func testPostTooLongKeywordReturns400() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        let longKw = String(repeating: "a", count: 51)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/keywords",
                method: .post,
                headers: [
                    .authorization: "Bearer nnt_alice",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"keyword":"\#(longKw)"}"#)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
    }

    /// 같은 키워드 두 번 POST해도 201 + 한 row.
    func testPostDuplicateIsIdempotent() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        try await app.test(.router) { client in
            for _ in 0..<2 {
                try await client.execute(
                    uri: "/me/keywords",
                    method: .post,
                    headers: [
                        .authorization: "Bearer nnt_alice",
                        .contentType: "application/json",
                    ],
                    body: ByteBuffer(string: #"{"keyword":"갤럭시"}"#)
                ) { response in
                    XCTAssertEqual(response.status, .created)
                }
            }
        }
        XCTAssertEqual(try await store.listKeywords(uuid: "nnt_alice"), ["갤럭시"])
    }

    /// DELETE 경로 segment는 URL-encoded. 한글 포함 케이스 round-trip.
    func testDeleteRemovesKeyword() async throws {
        let (store, app) = try makeApp()
        try await store.upsertUser(uuid: "nnt_alice")
        try await store.addKeyword(uuid: "nnt_alice", keyword: "갤럭시")
        try await app.test(.router) { client in
            let encoded = "갤럭시"
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
            try await client.execute(
                uri: "/me/keywords/\(encoded)",
                method: .delete,
                headers: [.authorization: "Bearer nnt_alice"]
            ) { response in
                XCTAssertEqual(response.status, .noContent)
            }
        }
        XCTAssertTrue(try await store.listKeywords(uuid: "nnt_alice").isEmpty)
        await store.close()
    }

    /// 없는 키워드 DELETE도 204 (멱등). 스펙 §API 명시.
    func testDeleteNonexistentReturns204() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/keywords/none",
                method: .delete,
                headers: [.authorization: "Bearer nnt_alice"]
            ) { response in
                XCTAssertEqual(response.status, .noContent)
            }
        }
    }

    /// 사용자 격리. nnt_a의 키워드가 nnt_b GET에 안 나와야 함.
    func testListIsScopedPerUser() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/keywords",
                method: .post,
                headers: [
                    .authorization: "Bearer nnt_a",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"keyword":"galaxy"}"#)
            ) { _ in }

            try await client.execute(
                uri: "/me/keywords",
                method: .get,
                headers: [.authorization: "Bearer nnt_b"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "[]")
            }
        }
    }
}
```

- [ ] **Step 2: 실패 확인**

```bash
swift test --filter KeywordRoutesTests
```

Expected: 모두 404 또는 미존재 fail.

- [ ] **Step 3: KeywordRoutes 작성**

`Server/Sources/NuntingServer/Routes/KeywordRoutes.swift`:
```swift
import Hummingbird

struct KeywordRoutes {
    let store: Store
    static let maxKeywordLength = 50

    struct PostKeywordRequest: Decodable {
        let keyword: String
    }

    func add(to router: RouterGroup<UserRequestContext>) {
        router.get("/keywords") { _, context -> [String] in
            try await store.listKeywords(uuid: try context.requireUUID())
        }

        router.post("/keywords") { request, context -> EditedResponse<String> in
            let body = try await request.decode(as: PostKeywordRequest.self, context: context)
            let normalized = Store.normalizedKeyword(body.keyword)
            guard !normalized.isEmpty else { throw HTTPError(.badRequest) }
            guard normalized.count <= Self.maxKeywordLength else { throw HTTPError(.badRequest) }
            let uuid = try context.requireUUID()
            try await store.addKeyword(uuid: uuid, keyword: normalized)
            return EditedResponse(status: .created, response: normalized)
        }

        router.delete("/keywords/{keyword}") { _, context -> HTTPResponse.Status in
            let raw = try context.parameters.require("keyword")
            let normalized = Store.normalizedKeyword(raw)
            let uuid = try context.requireUUID()
            try await store.removeKeyword(uuid: uuid, keyword: normalized)
            return .noContent
        }
    }
}
```

- [ ] **Step 4: App.swift에 마운트**

`App.swift`의 `authed` 그룹에 추가:
```swift
PushTokenRoutes(store: store).add(to: authed)
KeywordRoutes(store: store).add(to: authed)
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
swift test --filter KeywordRoutesTests
```

Expected: 8 tests passed.

- [ ] **Step 6: 전체 테스트 통과 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift test
```

Expected: 전체 ~19개 테스트 passed.

- [ ] **Step 7: 커밋**

```bash
git add Server/Sources/NuntingServer/Routes/KeywordRoutes.swift Server/Sources/NuntingServer/App.swift Server/Tests/NuntingServerTests/KeywordRoutesTests.swift
git commit -m "feat(server): GET/POST/DELETE /me/keywords"
```

---

## Task 8: 수동 curl 검증 + 마무리 커밋

**Files:**
- (없음, 검증만)

- [ ] **Step 1: 빌드 + 서버 기동**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift build
NUNTING_DB_PATH=/tmp/nunting-smoke.db swift run NuntingServer &
SERVER_PID=$!
sleep 2
```

- [ ] **Step 2: /health curl**

```bash
curl -s http://127.0.0.1:8080/health
```

Expected: `ok`

- [ ] **Step 3: 인증 누락 401**

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/me/keywords
```

Expected: `401`

- [ ] **Step 4: 키워드 POST + GET**

```bash
curl -s -X POST http://127.0.0.1:8080/me/keywords \
  -H "Authorization: Bearer nnt_smoke-test" \
  -H "Content-Type: application/json" \
  -d '{"keyword":"Galaxy S25"}' && echo
curl -s http://127.0.0.1:8080/me/keywords \
  -H "Authorization: Bearer nnt_smoke-test"
```

Expected:
- POST 응답: `"galaxy s25"`
- GET 응답: `["galaxy s25"]`

- [ ] **Step 5: 푸시 토큰 PUT + sqlite 확인**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X PUT \
  http://127.0.0.1:8080/me/push-token \
  -H "Authorization: Bearer nnt_smoke-test" \
  -H "Content-Type: application/json" \
  -d '{"token":"deadbeef"}'
sqlite3 /tmp/nunting-smoke.db "SELECT uuid, push_token FROM users;"
```

Expected:
- HTTP 204
- sqlite3: `nnt_smoke-test|deadbeef`

- [ ] **Step 6: DELETE 키워드**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X DELETE \
  "http://127.0.0.1:8080/me/keywords/galaxy%20s25" \
  -H "Authorization: Bearer nnt_smoke-test"
curl -s http://127.0.0.1:8080/me/keywords \
  -H "Authorization: Bearer nnt_smoke-test"
```

Expected:
- HTTP 204
- GET 응답: `[]`

- [ ] **Step 7: 서버 종료 + cleanup**

```bash
kill $SERVER_PID
rm -f /tmp/nunting-smoke.db
```

- [ ] **Step 8: (검증만 한 경우 추가 커밋 불필요)**

Task 7까지의 커밋이 PR B의 최종 상태. 추가 변경이 있었다면(예: 스모크 중 발견한 버그 수정) 별도 커밋.

---

## Self-Review

### Spec coverage check (`docs/superpowers/specs/2026-05-12-ppomppu-keyword-push-design.md` §마이그레이션 단계 2)

| 스펙 항목 | 다루는 Task |
|----------|-----------|
| `Server/` SPM executable 패키지 | Task 1 |
| Hummingbird 보일러플레이트 | Task 1, 5 |
| BearerMiddleware | Task 5 |
| Store (SQLite) | Task 2~4 |
| `PUT /me/push-token` | Task 6 |
| `GET /me/keywords` | Task 7 |
| `POST /me/keywords` | Task 7 |
| `DELETE /me/keywords/{keyword}` | Task 7 |
| 키워드 정규화 (trim + lowercase) | Task 4, 7 |
| 50자 제한, 빈 문자열 400 | Task 7 |
| 중복 POST 멱등, 없는 DELETE 멱등 | Task 4, 7 |
| `users.push_token` NULL 허용 | Task 3, 6 |
| Foreign key ON DELETE CASCADE | Task 2 (PRAGMA + Schema) |
| `idx_users_with_token` 부분 인덱스 | Task 2 (Schema) |
| macOS에서 curl로 CRUD 확인 | Task 8 |

### 비범위 (의도적)

- 폴러 / APNs / iOS UI / Docker / Cloudflare Tunnel — PR C/D/E.
- `users.created_at` round-trip 외 read API — 폴러가 PR C에서 필요할 때 추가.
- `NUNTING_PORT` 환경변수 — 8080 하드코딩으로 충분, 필요해지면 PR E.

### 타입 일관성 체크

- `Store` 메서드 시그니처: `addKeyword(uuid:keyword:)`, `listKeywords(uuid:)`, `removeKeyword(uuid:keyword:)`, `setPushToken(uuid:token:)`, `upsertUser(uuid:)` — Task 3/4/5/6/7에서 동일.
- `Store.normalizedKeyword(_:)` static — Task 4에서 정의, Task 7 라우트에서 사용.
- `UserRequestContext.userUUID: String?` + `requireUUID() -> String throws` — Task 5에서 정의, Task 6/7에서 사용.
- `buildApp(store:)` 시그니처 — Task 1에서 인자 없음 → Task 5에서 `(store:)` 추가. Test/main 모두 갱신됨.

### Placeholder scan

PR 본문 또는 README 작성은 의도적으로 plan에 없음(스펙 PR E에서 운영 가이드로 분리). "TBD"/"...later" 표현 없음 확인.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-13-plan2-server-minimum.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Plan 1과 동일한 패턴. task별로 fresh subagent를 띄우고 사이사이 리뷰.

**2. Inline Execution** — 이 세션에서 직접 task를 진행.

Which approach?
