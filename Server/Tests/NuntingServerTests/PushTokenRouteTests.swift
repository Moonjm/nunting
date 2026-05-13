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
