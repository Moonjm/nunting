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
