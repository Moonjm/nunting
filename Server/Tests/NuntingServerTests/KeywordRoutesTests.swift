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
        let listed = try await store.listKeywords(uuid: "nnt_alice")
        XCTAssertEqual(listed, ["galaxy s25"])
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

    /// 50자(maxKeywordLength) 경계는 통과해야 함.
    /// `count <= 50` → `count < 50`으로 잘못 바꿔도 회귀로 잡힌다.
    func testPostKeywordAtMaxLengthReturns201() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        let maxKw = String(repeating: "a", count: 50)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/keywords",
                method: .post,
                headers: [
                    .authorization: "Bearer nnt_alice",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"keyword":"\#(maxKw)"}"#)
            ) { response in
                XCTAssertEqual(response.status, .created)
            }
        }
    }

    /// GET 응답이 Store의 `ORDER BY keyword`를 그대로 propagate해 알파벳 정렬됨.
    /// listKeywords의 ORDER BY가 라우트 응답까지 보존되는지 end-to-end로 pin.
    func testListReturnsAlphabeticallySortedKeywords() async throws {
        let (store, app) = try makeApp()
        defer { Task { await store.close() } }
        try await app.test(.router) { client in
            for kw in ["banana", "apple"] {
                try await client.execute(
                    uri: "/me/keywords",
                    method: .post,
                    headers: [
                        .authorization: "Bearer nnt_alice",
                        .contentType: "application/json",
                    ],
                    body: ByteBuffer(string: #"{"keyword":"\#(kw)"}"#)
                ) { _ in }
            }
            try await client.execute(
                uri: "/me/keywords",
                method: .get,
                headers: [.authorization: "Bearer nnt_alice"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), #"["apple","banana"]"#)
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
        let listed = try await store.listKeywords(uuid: "nnt_alice")
        XCTAssertEqual(listed, ["갤럭시"])
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
        let listed = try await store.listKeywords(uuid: "nnt_alice")
        XCTAssertTrue(listed.isEmpty)
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
