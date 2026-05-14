import XCTest
import CryptoKit
@testable import NuntingServer

final class APNsClientTests: XCTestCase {
    /// stub HTTPRequester로 200 응답 → .ok 반환.
    /// 동시에 호출된 URL/헤더가 APNs 규약 (bearer JWT, apns-topic, /3/device/<token>)
    /// 을 만족하는지도 검증.
    func testSendReturnsOkOn200() async throws {
        let key = P256.Signing.PrivateKey()
        let config = APNsConfig(
            keyPath: "(unused — inline PEM)",
            keyId: "K1",
            teamId: "T1",
            topic: "com.example.app",
            host: "api.sandbox.push.apple.com"
        )

        let captured = CapturedRequest()
        let client = APNsClient(config: config, keyPEM: key.pemRepresentation) { url, headers, body in
            await captured.record(url: url, headers: headers, body: body)
            return (200, Data())
        }

        let payload = APNsPayload(
            title: "뽐뿌 — 갤럭시",
            body: "갤럭시 S25 핫딜",
            url: URL(string: "https://www.ppomppu.co.kr/...")!
        )
        let result = try await client.send(deviceToken: "DEVICETOKEN123", payload: payload)
        XCTAssertEqual(result, .ok)

        let recorded = await captured.snapshot()
        XCTAssertEqual(recorded.url?.absoluteString, "https://api.sandbox.push.apple.com/3/device/DEVICETOKEN123")
        XCTAssertEqual(recorded.headers?["apns-topic"], "com.example.app")
        XCTAssertTrue(recorded.headers?["authorization"]?.hasPrefix("bearer ") == true)
        XCTAssertGreaterThan(recorded.body?.count ?? 0, 0)
    }

    /// 410 → .unregistered. 폴러가 이걸 보고 push_token=NULL 처리한다.
    func testSendReturnsUnregisteredOn410() async throws {
        let key = P256.Signing.PrivateKey()
        let config = Self.testConfig
        let client = APNsClient(config: config, keyPEM: key.pemRepresentation) { _, _, _ in
            (410, Data())
        }
        let result = try await client.send(
            deviceToken: "BAD",
            payload: Self.testPayload
        )
        XCTAssertEqual(result, .unregistered)
    }

    /// 429 → backoff 후 재시도. 4회째 호출 안 함, 3회 모두 429면 .retryExhausted.
    func testSendRetriesOn429UpToThreeAttempts() async throws {
        let key = P256.Signing.PrivateKey()
        let config = Self.testConfig
        let attempts = AttemptCounter()
        let client = APNsClient(
            config: config,
            keyPEM: key.pemRepresentation,
            retryDelay: { _ in .milliseconds(1) }  // 테스트 속도용 짧은 backoff
        ) { _, _, _ in
            await attempts.increment()
            return (429, Data())
        }
        let result = try await client.send(deviceToken: "X", payload: Self.testPayload)
        XCTAssertEqual(result, .retryExhausted)
        let count = await attempts.value
        XCTAssertEqual(count, 3, "최대 3회 시도")
    }

    /// 400 같은 영구 실패는 retry 없이 즉시 .fail.
    func testSendReturnsFailOn400() async throws {
        let key = P256.Signing.PrivateKey()
        let config = Self.testConfig
        let attempts = AttemptCounter()
        let client = APNsClient(config: config, keyPEM: key.pemRepresentation) { _, _, _ in
            await attempts.increment()
            return (400, "BadDeviceToken".data(using: .utf8)!)
        }
        let result = try await client.send(deviceToken: "X", payload: Self.testPayload)
        switch result {
        case .fail(let status, let body):
            XCTAssertEqual(status, 400)
            XCTAssertEqual(body, "BadDeviceToken")
        default:
            XCTFail("expected .fail, got \(result)")
        }
        let count = await attempts.value
        XCTAssertEqual(count, 1, "400은 retry 없이 즉시 종료")
    }

    /// 같은 client로 send를 두 번 연속 호출하면 JWT가 캐시되어야 한다.
    /// 새 토큰을 매번 발급하면 APNs가 throttle 가능성 있음.
    func testJWTIsCachedAcrossSends() async throws {
        let key = P256.Signing.PrivateKey()
        let config = Self.testConfig
        let observed = ObservedTokens()
        let client = APNsClient(config: config, keyPEM: key.pemRepresentation) { _, headers, _ in
            await observed.record(headers["authorization"] ?? "")
            return (200, Data())
        }
        _ = try await client.send(deviceToken: "X", payload: Self.testPayload)
        _ = try await client.send(deviceToken: "Y", payload: Self.testPayload)
        let tokens = await observed.snapshot()
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0], tokens[1], "JWT는 1시간 캐시")
    }

    // MARK: - Fixtures

    static let testConfig = APNsConfig(
        keyPath: "(inline)",
        keyId: "K",
        teamId: "T",
        topic: "com.example.app",
        host: "api.sandbox.push.apple.com"
    )

    static var testPayload: APNsPayload {
        APNsPayload(title: "t", body: "b", url: URL(string: "https://example.com")!)
    }
}

// MARK: - Test-only actors

private actor CapturedRequest {
    struct Snapshot {
        let url: URL?
        let headers: [String: String]?
        let body: Data?
    }
    private var url: URL?
    private var headers: [String: String]?
    private var body: Data?

    func record(url: URL, headers: [String: String], body: Data) {
        self.url = url
        self.headers = headers
        self.body = body
    }
    func snapshot() -> Snapshot { Snapshot(url: url, headers: headers, body: body) }
}

private actor AttemptCounter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}

private actor ObservedTokens {
    private var tokens: [String] = []
    func record(_ token: String) { tokens.append(token) }
    func snapshot() -> [String] { tokens }
}
