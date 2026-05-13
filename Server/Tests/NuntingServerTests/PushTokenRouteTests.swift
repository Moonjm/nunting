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
        let stored = try await store.pushToken(uuid: "nnt_alice")
        XCTAssertEqual(stored, "aabbccdd")
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
        let after = try await store.pushToken(uuid: "nnt_alice")
        XCTAssertNil(after)
        await store.close()
    }

    /// 256자 초과 token은 400. APNs deviceToken은 64 hex (~200 bytes) 고정이라
    /// 그 이상은 abuse로 간주, DB row 비대를 막는다.
    func testPutPushTokenRejectsOversizedToken() async throws {
        let store = try Store(path: ":memory:")
        let app = buildApp(store: store)
        let huge = String(repeating: "a", count: 257)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/me/push-token",
                method: .put,
                headers: [
                    .authorization: "Bearer nnt_alice",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"token":"\#(huge)"}"#)
            ) { response in
                XCTAssertEqual(response.status, .badRequest)
            }
        }
        let stored = try await store.pushToken(uuid: "nnt_alice")
        XCTAssertNil(stored, "거대 token은 저장되지 않아야 함")
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
