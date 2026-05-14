# Plan 3 — Poller + APNs (PR C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 뽐뿌 게시판을 3분 주기로 폴링해 새 글 중 사용자가 등록한 키워드와 매칭되는 것을 APNs로 푸시한다. iOS는 PR D 이후 — 본 PR은 서버에서 실제 APNs sandbox로 한 발 전송이 가는 것까지가 마감 목표.

**Architecture:**
- Hummingbird `Service`로 폴러 백그라운드 루프를 HTTP 서버와 같은 lifecycle에 연결한다(SIGTERM 시 graceful cancel).
- 폴러는 actor로 `lastSeenPostId` 상태만 들고, fetcher/Store/APNs는 외부 주입(closure 또는 actor reference). 키워드 매칭은 pure static 함수로 분리해 단위 테스트.
- APNs 클라이언트는 외부 라이브러리 없이 `CryptoKit` 직접 사용(ES256 JWT) + `URLSession` HTTP/2. JWT 1시간 만료 캐시. 429/500/503 backoff 재시도(최대 3회). 410 응답은 `users.push_token = NULL`로 self-heal.

**Tech Stack:**
- Swift 6.0 toolchain, swift-tools-version 6.0
- 기존 Hummingbird 2.x + NuntingCore 그대로
- `CryptoKit` (Apple) — P256 ECDSA, macOS 14+ 시스템 라이브러리
- `URLSession` (Foundation) — HTTP/2 자동
- XCTest

---

## File Structure

```
Server/
├── Package.swift                                              # 수정: 없음 (CryptoKit/Foundation 둘 다 system)
├── Sources/NuntingServer/
│   ├── APNs/
│   │   ├── APNsConfig.swift                                   # 신규: env에서 읽는 설정 struct
│   │   ├── APNsPayload.swift                                  # 신규: aps/alert/url Codable
│   │   ├── APNsJWT.swift                                      # 신규: ES256 서명 + base64url
│   │   └── APNsClient.swift                                   # 신규: actor + send + retry + cache
│   ├── Poller/
│   │   ├── KeywordMatcher.swift                               # 신규: pure static 매칭
│   │   ├── PpomppuPoller.swift                                # 신규: actor + sentinel walk + tick
│   │   └── PollerService.swift                                # 신규: Hummingbird Service for 3-min loop
│   ├── Net/
│   │   └── ServerNetworking.swift                             # 신규: URLSession + UA + encoding
│   ├── DB/
│   │   └── Store.swift                                        # 수정: extension에 usersWithKeywords
│   ├── App.swift                                              # 수정: buildApp이 additional services 받음
│   └── main.swift                                             # 수정: APNs config + poller 와이어
└── Tests/NuntingServerTests/
    ├── APNsJWTTests.swift                                     # 신규: 서명 round-trip
    ├── APNsClientTests.swift                                  # 신규: stub requester로 retry/410/200
    ├── KeywordMatcherTests.swift                              # 신규: pure 매칭 케이스
    ├── PpomppuPollerTests.swift                               # 신규: sentinel walk + 매칭→푸시 + 410
    └── StoreTests.swift                                       # 수정: usersWithKeywords 케이스 추가
```

파일별 책임:
- `APNsConfig.swift`: `struct APNsConfig` — keyPath, keyId, teamId, topic, host. env 파싱은 main.swift 책임이라 여긴 데이터만.
- `APNsPayload.swift`: `struct APNsPayload: Encodable` + nested `APS`/`Alert`. 응답 코드는 `APNsResult` enum.
- `APNsJWT.swift`: `enum APNsJWT` — `makeToken(config:now:)` 정적 함수. base64url helper.
- `APNsClient.swift`: `public actor APNsClient` — `send(deviceToken:payload:)`. `HTTPRequester` closure DI. JWT 캐시 actor state.
- `KeywordMatcher.swift`: `enum KeywordMatcher` — `match(posts:subscriptions:)` pure static.
- `PpomppuPoller.swift`: `public actor PpomppuPoller` — `tick()`. 의존성: fetcher closure + Store actor + APNsClient actor.
- `PollerService.swift`: `struct PollerService: Service` — Hummingbird/swift-service-lifecycle 호환. `run()` 루프.
- `ServerNetworking.swift`: `enum ServerNetworking` — `fetchHTML(url:encoding:)` static. UA + euc-kr 디코드.
- `Store.swift` extension: `usersWithKeywords()` — `[(uuid, pushToken, Set<keyword>)]` 스냅샷.
- `App.swift`: `buildApp(store:additionalServices:)`로 시그니처 확장.
- `main.swift`: env 검증 + APNs config + Poller 구성 + service array 빌드 + runService.

---

## Task 1: APNs 데이터 타입 (Config + Payload + JWT)

**Files:**
- Create: `Server/Sources/NuntingServer/APNs/APNsConfig.swift`
- Create: `Server/Sources/NuntingServer/APNs/APNsPayload.swift`
- Create: `Server/Sources/NuntingServer/APNs/APNsJWT.swift`
- Create: `Server/Tests/NuntingServerTests/APNsJWTTests.swift`

- [ ] **Step 1: APNsJWT 실패 테스트**

`Server/Tests/NuntingServerTests/APNsJWTTests.swift`:
```swift
import XCTest
import CryptoKit
@testable import NuntingServer

final class APNsJWTTests: XCTestCase {
    /// ephemeral P256 key 쌍을 만들고, makeToken으로 서명한 뒤 같은 public key로
    /// 검증. RFC 7519 JWT는 base64url(header).base64url(payload).base64url(sig)
    /// 구조. APNs는 ES256(alg) + raw r||s 64바이트 서명을 요구한다.
    func testMakeTokenProducesValidES256Signature() throws {
        let priv = P256.Signing.PrivateKey()
        let pem = priv.pemRepresentation
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let jwt = try APNsJWT.makeToken(
            keyPEM: pem,
            keyId: "ABC123KEY",
            teamId: "TEAM12345",
            now: now
        )

        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "JWT는 header.payload.sig 3분할")

        // header
        let headerJSON = try APNsJWTTests.decodeBase64URL(String(parts[0]))
        let header = try JSONSerialization.jsonObject(with: headerJSON) as? [String: String]
        XCTAssertEqual(header?["alg"], "ES256")
        XCTAssertEqual(header?["kid"], "ABC123KEY")

        // payload
        let payloadJSON = try APNsJWTTests.decodeBase64URL(String(parts[1]))
        let payload = try JSONSerialization.jsonObject(with: payloadJSON) as? [String: Any]
        XCTAssertEqual(payload?["iss"] as? String, "TEAM12345")
        XCTAssertEqual(payload?["iat"] as? Int, 1_700_000_000)

        // signature
        let sigBytes = try APNsJWTTests.decodeBase64URL(String(parts[2]))
        XCTAssertEqual(sigBytes.count, 64, "ES256 raw r||s는 64바이트")

        // round-trip verify
        let signingInput = "\(parts[0]).\(parts[1])".data(using: .utf8)!
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: sigBytes)
        XCTAssertTrue(priv.publicKey.isValidSignature(signature, for: signingInput))
    }

    static func decodeBase64URL(_ s: String) throws -> Data {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64.append(String(repeating: "=", count: pad))
        guard let data = Data(base64Encoded: b64) else {
            struct DecodeError: Error {}
            throw DecodeError()
        }
        return data
    }
}
```

- [ ] **Step 2: 실패 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift test --filter APNsJWTTests
```

Expected: `error: cannot find 'APNsJWT' in scope`.

- [ ] **Step 3: APNsConfig 작성**

`Server/Sources/NuntingServer/APNs/APNsConfig.swift`:
```swift
import Foundation

/// APNs 자격 정보 + 엔드포인트 묶음.
///
/// `keyPath`: Apple Developer Portal에서 받은 `.p8` 파일의 절대 경로
/// `keyId`: `.p8` 파일과 짝지어진 Key ID (Apple Developer Portal 표시)
/// `teamId`: Apple Developer Team ID
/// `topic`: bundle id (예: `com.moonjm.nunting`)
/// `host`: `api.push.apple.com`(production) 또는 `api.sandbox.push.apple.com`(sandbox)
public struct APNsConfig: Sendable {
    public let keyPath: String
    public let keyId: String
    public let teamId: String
    public let topic: String
    public let host: String

    public init(keyPath: String, keyId: String, teamId: String, topic: String, host: String) {
        self.keyPath = keyPath
        self.keyId = keyId
        self.teamId = teamId
        self.topic = topic
        self.host = host
    }
}
```

- [ ] **Step 4: APNsPayload 작성**

`Server/Sources/NuntingServer/APNs/APNsPayload.swift`:
```swift
import Foundation

/// 스펙 §푸시 페이로드 그대로.
/// 커스텀 `url` 키는 iOS의 `didReceive` 핸들러가 deep-link에 사용.
public struct APNsPayload: Encodable, Sendable {
    public let aps: APS
    public let url: URL

    public struct APS: Encodable, Sendable {
        public let alert: Alert
        public let sound: String
    }

    public struct Alert: Encodable, Sendable {
        public let title: String
        public let body: String
    }

    public init(title: String, body: String, url: URL, sound: String = "default") {
        self.aps = APS(alert: Alert(title: title, body: body), sound: sound)
        self.url = url
    }
}

/// APNs 응답 해석 결과. 호출자가 이걸 보고 retry/NULL 처리 결정.
public enum APNsResult: Sendable, Equatable {
    /// 200 성공
    case ok
    /// 410 Unregistered — 토큰 무효, 호출자가 `users.push_token = NULL` 처리.
    case unregistered
    /// 429/500/503 — APNsClient 내부에서 이미 backoff 3회 시도 후 포기한 결과.
    /// 호출자는 다음 tick에 다시 시도하면 됨.
    case retryExhausted
    /// 그 외 4xx/5xx — 영구 실패. body는 디버그 로그용.
    case fail(status: Int, body: String)
}
```

- [ ] **Step 5: APNsJWT 작성**

`Server/Sources/NuntingServer/APNs/APNsJWT.swift`:
```swift
import Foundation
import CryptoKit

/// APNs provider JWT 서명. ES256 + raw r||s 64바이트 + base64url 인코딩.
/// JWT는 1시간 만료(APNs 규약). 호출자가 캐시 책임을 갖는다(APNsClient가 actor
/// state로 관리).
enum APNsJWT {
    enum Error: Swift.Error {
        case invalidPEM
        case signingFailed
    }

    /// `keyPEM`: `-----BEGIN PRIVATE KEY-----` 포함 PEM 문자열 전체.
    static func makeToken(
        keyPEM: String,
        keyId: String,
        teamId: String,
        now: Date
    ) throws -> String {
        let signingKey: P256.Signing.PrivateKey
        do {
            signingKey = try P256.Signing.PrivateKey(pemRepresentation: keyPEM)
        } catch {
            throw Error.invalidPEM
        }

        let headerJSON = #"{"alg":"ES256","kid":"\#(keyId)","typ":"JWT"}"#
        let payloadJSON = #"{"iss":"\#(teamId)","iat":\#(Int(now.timeIntervalSince1970))}"#

        let headerEncoded = base64URL(headerJSON.data(using: .utf8)!)
        let payloadEncoded = base64URL(payloadJSON.data(using: .utf8)!)
        let signingInput = "\(headerEncoded).\(payloadEncoded)"

        let signature: P256.Signing.ECDSASignature
        do {
            signature = try signingKey.signature(for: signingInput.data(using: .utf8)!)
        } catch {
            throw Error.signingFailed
        }
        let sigEncoded = base64URL(signature.rawRepresentation)
        return "\(signingInput).\(sigEncoded)"
    }

    /// base64url (RFC 4648 §5) — `+` → `-`, `/` → `_`, padding `=` 제거.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
```

- [ ] **Step 6: 테스트 통과 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift test --filter APNsJWTTests
```

Expected: 1 test passed.

- [ ] **Step 7: 커밋**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
git add Server/Sources/NuntingServer/APNs/ Server/Tests/NuntingServerTests/APNsJWTTests.swift
git commit -m "feat(server): APNs JWT ES256 + Config/Payload 타입"
```

---

## Task 2: APNsClient — HTTP/2 send + retry + JWT cache

**Files:**
- Create: `Server/Sources/NuntingServer/APNs/APNsClient.swift`
- Create: `Server/Tests/NuntingServerTests/APNsClientTests.swift`

- [ ] **Step 1: 실패 테스트**

`Server/Tests/NuntingServerTests/APNsClientTests.swift`:
```swift
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
```

- [ ] **Step 2: 실패 확인**

```bash
swift test --filter APNsClientTests
```

Expected: `cannot find 'APNsClient' in scope`.

- [ ] **Step 3: APNsClient 작성**

`Server/Sources/NuntingServer/APNs/APNsClient.swift`:
```swift
import Foundation

/// APNs HTTP/2 provider 클라이언트. JWT 1시간 캐시 + 429/500/503 backoff
/// 재시도(최대 3회). 다른 상태 코드는 즉시 결과로 변환.
///
/// 테스트는 `HTTPRequester` closure로 in-process stub을 주입한다.
/// 프로덕션은 `URLSession.shared`을 감싸는 closure를 main.swift에서 주입.
public actor APNsClient {
    public typealias HTTPRequester = @Sendable (
        _ url: URL,
        _ headers: [String: String],
        _ body: Data
    ) async throws -> (statusCode: Int, body: Data)

    public typealias RetryDelay = @Sendable (_ attempt: Int) -> Duration

    private let config: APNsConfig
    private let keyPEM: String
    private let requester: HTTPRequester
    private let retryDelay: RetryDelay
    private let now: @Sendable () -> Date

    /// JWT는 1시간 만료. 50분 단위로 재발급한다(10분 safety margin).
    private static let tokenLifetime: TimeInterval = 50 * 60

    private var cachedToken: (token: String, expiresAt: Date)?

    public init(
        config: APNsConfig,
        keyPEM: String,
        now: @escaping @Sendable () -> Date = { Date() },
        retryDelay: @escaping RetryDelay = { attempt in
            // exponential: 1s, 2s
            .seconds(1 << attempt)
        },
        requester: @escaping HTTPRequester
    ) {
        self.config = config
        self.keyPEM = keyPEM
        self.now = now
        self.retryDelay = retryDelay
        self.requester = requester
    }

    public func send(deviceToken: String, payload: APNsPayload) async throws -> APNsResult {
        let body = try JSONEncoder().encode(payload)
        let url = URL(string: "https://\(config.host)/3/device/\(deviceToken)")!

        var lastResult: APNsResult = .retryExhausted
        for attempt in 0..<3 {
            let token = try currentJWT()
            let headers: [String: String] = [
                "authorization": "bearer \(token)",
                "apns-topic": config.topic,
                "apns-push-type": "alert",
                "content-type": "application/json",
            ]
            let (status, respBody) = try await requester(url, headers, body)
            switch status {
            case 200:
                return .ok
            case 410:
                return .unregistered
            case 429, 500, 503:
                lastResult = .retryExhausted
                if attempt < 2 {
                    try await Task.sleep(for: retryDelay(attempt))
                    continue
                }
            default:
                return .fail(
                    status: status,
                    body: String(data: respBody, encoding: .utf8) ?? "(non-utf8 body)"
                )
            }
        }
        return lastResult
    }

    /// 캐시된 JWT가 expiry보다 미래면 재사용, 아니면 새로 발급.
    private func currentJWT() throws -> String {
        let nowDate = now()
        if let cached = cachedToken, cached.expiresAt > nowDate {
            return cached.token
        }
        let token = try APNsJWT.makeToken(
            keyPEM: keyPEM,
            keyId: config.keyId,
            teamId: config.teamId,
            now: nowDate
        )
        cachedToken = (token, nowDate.addingTimeInterval(Self.tokenLifetime))
        return token
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
swift test --filter APNsClientTests
```

Expected: 5 tests passed.

- [ ] **Step 5: 커밋**

```bash
git add Server/Sources/NuntingServer/APNs/APNsClient.swift Server/Tests/NuntingServerTests/APNsClientTests.swift
git commit -m "feat(server): APNsClient HTTP/2 send + JWT 캐시 + 429 backoff"
```

---

## Task 3: KeywordMatcher — pure 매칭

**Files:**
- Create: `Server/Sources/NuntingServer/Poller/KeywordMatcher.swift`
- Create: `Server/Tests/NuntingServerTests/KeywordMatcherTests.swift`

- [ ] **Step 1: 실패 테스트**

`Server/Tests/NuntingServerTests/KeywordMatcherTests.swift`:
```swift
import XCTest
import NuntingCore
@testable import NuntingServer

final class KeywordMatcherTests: XCTestCase {
    private static let board = Board(
        id: "ppomppu",
        site: .ppomppu,
        name: "뽐뿌게시판",
        path: "/zboard/zboard.php?id=ppomppu"
    )

    private static func makePost(id: String, title: String) -> Post {
        Post(
            id: id,
            site: .ppomppu,
            boardID: board.id,
            title: title,
            author: "a",
            date: nil,
            dateText: "",
            commentCount: 0,
            url: URL(string: "https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=\(id)")!
        )
    }

    /// 단일 사용자, 단일 키워드, 1건 매칭.
    func testSingleUserSingleKeywordMatches() {
        let post = Self.makePost(id: "1", title: "갤럭시 S25 핫딜 19만원")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_alice": ["갤럭시"]]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].uuid, "nnt_alice")
        XCTAssertEqual(result[0].keyword, "갤럭시")
        XCTAssertEqual(result[0].post.id, "1")
    }

    /// 두 사용자, 한 명만 매칭.
    func testOnlyMatchingUserGetsResult() {
        let post = Self.makePost(id: "1", title: "RTX 5090 핫딜")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: [
                "nnt_a": ["rtx5090"],
                "nnt_b": ["맥북"],
            ]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].uuid, "nnt_a")
    }

    /// 매칭은 title.lowercased().contains(keyword) — keyword는 이미 normalize됨 가정.
    /// 대소문자/공백 정규화는 호출자 책임(Store.normalizedKeyword + KeywordMatcher
    /// 내부의 title.lowercased()).
    func testMatchingIsCaseInsensitiveForLatinKeywords() {
        let post = Self.makePost(id: "1", title: "Galaxy S25 hot deal")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["galaxy"]]
        )
        XCTAssertEqual(result.count, 1)
    }

    /// 한 글에 여러 키워드 매칭되면 각각 emit.
    /// 사용자가 "갤럭시", "S25"를 둘 다 구독했고 글이 "갤럭시 S25"면 2건.
    func testMultipleKeywordsMatchEmitsEachSeparately() {
        let post = Self.makePost(id: "1", title: "갤럭시 s25 핫딜")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["갤럭시", "s25"]]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.keyword)), ["갤럭시", "s25"])
    }

    /// 매칭 없는 글은 결과에 안 들어감.
    func testNonMatchingPostYieldsEmpty() {
        let post = Self.makePost(id: "1", title: "전혀 관련 없는 내용")
        let result = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["갤럭시"]]
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// posts 순서는 보존, 같은 글의 여러 매칭은 keyword 정렬로 안정화.
    /// ForEach 안정성 / 푸시 발송 순서 일관성을 위해.
    func testResultIsDeterministicWhenMultipleMatchesPerPost() {
        let post = Self.makePost(id: "1", title: "a b c")
        let result1 = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["c", "a", "b"]]
        )
        let result2 = KeywordMatcher.match(
            posts: [post],
            subscriptions: ["nnt_a": ["b", "c", "a"]]
        )
        XCTAssertEqual(result1.map(\.keyword), result2.map(\.keyword))
    }
}
```

- [ ] **Step 2: 실패 확인**

```bash
swift test --filter KeywordMatcherTests
```

Expected: `cannot find 'KeywordMatcher' in scope`.

- [ ] **Step 3: KeywordMatcher 작성**

`Server/Sources/NuntingServer/Poller/KeywordMatcher.swift`:
```swift
import NuntingCore

/// pure 매칭 함수 모음. Store 또는 APNs와 무관 — 단위 테스트가 가벼움.
///
/// 매칭 정규화: `post.title.lowercased()`와 `keyword`(이미
/// `Store.normalizedKeyword`를 통과해 lowercased + trimmed 상태) 사이의
/// `String.contains`. 한글은 lowercase가 no-op이지만 영문은 의미 있음.
enum KeywordMatcher {
    struct Match: Sendable, Hashable {
        let post: Post
        let uuid: String
        let keyword: String
    }

    /// posts 순서를 보존. 한 post에 여러 (uuid, keyword) 매칭이 있으면 emit 여러 번.
    /// 같은 post 안에서는 (uuid 사전순, keyword 사전순)로 정렬해 결정적 순서 보장.
    static func match(
        posts: [Post],
        subscriptions: [String: Set<String>]
    ) -> [Match] {
        var out: [Match] = []
        for post in posts {
            let titleLower = post.title.lowercased()
            var perPost: [Match] = []
            for (uuid, keywords) in subscriptions {
                for keyword in keywords where titleLower.contains(keyword) {
                    perPost.append(Match(post: post, uuid: uuid, keyword: keyword))
                }
            }
            perPost.sort { lhs, rhs in
                if lhs.uuid != rhs.uuid { return lhs.uuid < rhs.uuid }
                return lhs.keyword < rhs.keyword
            }
            out.append(contentsOf: perPost)
        }
        return out
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
swift test --filter KeywordMatcherTests
```

Expected: 6 tests passed.

- [ ] **Step 5: 커밋**

```bash
git add Server/Sources/NuntingServer/Poller/KeywordMatcher.swift Server/Tests/NuntingServerTests/KeywordMatcherTests.swift
git commit -m "feat(server): KeywordMatcher pure 매칭 함수"
```

---

## Task 4: Store.usersWithKeywords 스냅샷

**Files:**
- Modify: `Server/Sources/NuntingServer/DB/Store.swift`
- Modify: `Server/Tests/NuntingServerTests/StoreTests.swift`

- [ ] **Step 1: 실패 테스트**

`StoreTests.swift`에 추가:
```swift
/// `users.push_token IS NOT NULL`인 사용자의 (uuid, push_token, Set<keyword>) 스냅샷.
/// 폴러가 매 tick마다 한 번 호출한다. push_token NULL인 사용자는 제외 — 발송 대상 아님.
func testUsersWithKeywordsExcludesUsersWithoutPushToken() async throws {
    let store = try Store(path: ":memory:")
    defer { Task { await store.close() } }
    try await store.upsertUser(uuid: "nnt_with-token")
    try await store.setPushToken(uuid: "nnt_with-token", token: "tok-1")
    try await store.addKeyword(uuid: "nnt_with-token", keyword: "갤럭시")
    try await store.upsertUser(uuid: "nnt_no-token")
    try await store.addKeyword(uuid: "nnt_no-token", keyword: "맥북")

    let snapshot = try await store.usersWithKeywords()
    XCTAssertEqual(snapshot.count, 1)
    XCTAssertEqual(snapshot["nnt_with-token"]?.pushToken, "tok-1")
    XCTAssertEqual(snapshot["nnt_with-token"]?.keywords, ["갤럭시"])
    XCTAssertNil(snapshot["nnt_no-token"], "push_token NULL인 사용자는 제외")
}

/// 키워드 0개인 사용자는 스냅샷에 포함되되 빈 Set으로.
/// 단, 폴러는 빈 Set이면 매칭 0건이라 사실상 무시 — 단지 invariant pin.
func testUsersWithKeywordsReturnsEmptyKeywordSetIfNoneSubscribed() async throws {
    let store = try Store(path: ":memory:")
    defer { Task { await store.close() } }
    try await store.upsertUser(uuid: "nnt_a")
    try await store.setPushToken(uuid: "nnt_a", token: "tok")
    let snapshot = try await store.usersWithKeywords()
    XCTAssertEqual(snapshot["nnt_a"]?.keywords, [])
}

/// 여러 사용자가 같은 키워드를 구독하면 양쪽 스냅샷에 등장.
func testUsersWithKeywordsHandlesMultipleSubscribers() async throws {
    let store = try Store(path: ":memory:")
    defer { Task { await store.close() } }
    for uuid in ["nnt_a", "nnt_b"] {
        try await store.upsertUser(uuid: uuid)
        try await store.setPushToken(uuid: uuid, token: "tok-\(uuid)")
        try await store.addKeyword(uuid: uuid, keyword: "공통키워드")
    }
    let snapshot = try await store.usersWithKeywords()
    XCTAssertEqual(snapshot.count, 2)
    XCTAssertEqual(snapshot["nnt_a"]?.keywords, ["공통키워드"])
    XCTAssertEqual(snapshot["nnt_b"]?.keywords, ["공통키워드"])
}
```

- [ ] **Step 2: 실패 확인**

```bash
swift test --filter StoreTests
```

Expected: 3 new tests FAIL (`has no member 'usersWithKeywords'`).

- [ ] **Step 3: Store에 메서드 추가**

`Server/Sources/NuntingServer/DB/Store.swift`의 extension 끝(`listKeywords` 다음)에 추가:
```swift
public struct UserSubscription: Sendable {
    public let pushToken: String
    public let keywords: Set<String>

    public init(pushToken: String, keywords: Set<String>) {
        self.pushToken = pushToken
        self.keywords = keywords
    }
}

public func usersWithKeywords() throws -> [String: UserSubscription] {
    guard let db else { throw StoreError.sqlite(rc: 0, message: "store closed") }
    // 한 번의 LEFT JOIN으로 (users.uuid, users.push_token, keyword_subs.keyword)
    // 행을 받아 in-memory에서 group_by. push_token IS NOT NULL 필터.
    let sql = """
    SELECT u.uuid, u.push_token, ks.keyword
    FROM users u
    LEFT JOIN keyword_subs ks ON ks.uuid = u.uuid
    WHERE u.push_token IS NOT NULL;
    """
    var stmt: OpaquePointer?
    let pRC = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard pRC == SQLITE_OK, let stmt else {
        throw StoreError.sqlite(rc: pRC, message: String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(stmt) }

    // group rows by uuid
    var byUUID: [String: (pushToken: String, keywords: Set<String>)] = [:]
    while true {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW:
            guard let uuidPtr = sqlite3_column_text(stmt, 0),
                  let tokPtr = sqlite3_column_text(stmt, 1) else { continue }
            let uuid = String(cString: uuidPtr)
            let token = String(cString: tokPtr)
            var entry = byUUID[uuid] ?? (pushToken: token, keywords: [])
            if let kwPtr = sqlite3_column_text(stmt, 2) {
                entry.keywords.insert(String(cString: kwPtr))
            }
            byUUID[uuid] = entry
        case SQLITE_DONE:
            return byUUID.mapValues { UserSubscription(pushToken: $0.pushToken, keywords: $0.keywords) }
        default:
            throw StoreError.sqlite(rc: rc, message: String(cString: sqlite3_errmsg(db)))
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

```bash
swift test --filter StoreTests
```

Expected: 12 tests passed (기존 9 + 신규 3).

- [ ] **Step 5: 커밋**

```bash
git add Server/Sources/NuntingServer/DB/Store.swift Server/Tests/NuntingServerTests/StoreTests.swift
git commit -m "feat(server): Store.usersWithKeywords 스냅샷 메서드"
```

---

## Task 5: ServerNetworking — URLSession fetch + euc-kr 디코드

**Files:**
- Create: `Server/Sources/NuntingServer/Net/ServerNetworking.swift`

- [ ] **Step 1: 작성 (테스트 없음 — 네트워크 의존)**

`Server/Sources/NuntingServer/Net/ServerNetworking.swift`:
```swift
import Foundation

/// 서버 사이드 HTTP 페치. iOS 앱의 `Networking`과 별개로 두는 이유:
///  - 서버는 URLSession.shared 그대로 — 이미지 prefetch 같은 부가 기능 불필요.
///  - 인코딩 디코드는 동일하지만 의존성 모듈을 NuntingCore 밖에 둬서 iOS
///    번들에 서버 코드가 안 따라가게 한다.
///
/// 테스트가 없는 이유: 본 함수는 외부 HTTP 의존이고, 단위 테스트로 의미
/// 있는 검증은 fixture URL을 띄우는 것뿐인데 v1 비용 대비 효과가 낮다.
/// 폴러 단위 테스트는 이 함수 대신 stub fetcher closure를 주입한다.
enum ServerNetworking {
    static let userAgent =
        "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "nunting-server/0.1 Safari/537.36"

    static func fetchHTML(url: URL, encoding: String.Encoding) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return decodeHTML(data: data, encoding: encoding)
    }

    /// 1차로 명시 encoding 시도, 실패 시 UTF-8 fallback.
    static func decodeHTML(data: Data, encoding: String.Encoding) -> String {
        if let s = String(data: data, encoding: encoding) { return s }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
```

- [ ] **Step 2: 빌드 확인**

```bash
swift build
```

Expected: `Build complete!`

- [ ] **Step 3: 커밋**

```bash
git add Server/Sources/NuntingServer/Net/ServerNetworking.swift
git commit -m "feat(server): ServerNetworking — URLSession HTML fetch"
```

---

## Task 6: PpomppuPoller — actor + sentinel walk + 매칭→푸시

**Files:**
- Create: `Server/Sources/NuntingServer/Poller/PpomppuPoller.swift`
- Create: `Server/Tests/NuntingServerTests/PpomppuPollerTests.swift`

- [ ] **Step 1: 실패 테스트**

`Server/Tests/NuntingServerTests/PpomppuPollerTests.swift`:
```swift
import XCTest
import CryptoKit
import NuntingCore
@testable import NuntingServer

final class PpomppuPollerTests: XCTestCase {
    private static let board = Board(
        id: "ppomppu",
        site: .ppomppu,
        name: "뽐뿌게시판",
        path: "/zboard/zboard.php?id=ppomppu"
    )

    /// page=1 fixture에 글 2건. 첫 tick은 sentinel만 잡고 push 발송 안 함.
    /// 첫 실행에서 마지막 N개 글을 spam 푸시하면 사용자 경험 나쁨.
    func testFirstTickSetsSentinelWithoutSending() async throws {
        let html = Self.minimalListHTML(rows: [
            (no: "200", title: "두번째 글"),
            (no: "100", title: "첫번째 글"),
        ])
        let fetcher = StubFetcher(pages: ["1": html])
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.setPushToken(uuid: "nnt_a", token: "tok")
        try await store.addKeyword(uuid: "nnt_a", keyword: "첫번째")

        let apns = StubAPNs()
        let poller = PpomppuPoller(
            board: Self.board,
            store: store,
            apns: apns,
            fetcher: fetcher.fetch
        )
        await poller.tick()

        XCTAssertEqual(await apns.sentCount, 0, "첫 tick은 sentinel만 잡고 push 안 보냄")
    }

    /// 두 번째 tick에 새 글 등장 → 매칭 사용자에게 push 1회. 410 응답이면 store에서
    /// push_token NULL로 처리.
    func testSecondTickPushesMatchingPostThenHandles410() async throws {
        // 1차 페이지: 글 1건 (id=100)
        let firstHTML = Self.minimalListHTML(rows: [
            (no: "100", title: "기존 글"),
        ])
        // 2차 페이지: 새 글 2건 (id=300, 200), 그 다음 sentinel (id=100)
        let secondHTML = Self.minimalListHTML(rows: [
            (no: "300", title: "갤럭시 S25 핫딜"),
            (no: "200", title: "다른 글"),
            (no: "100", title: "기존 글"),
        ])
        let fetcher = StubFetcher(pages: ["1": firstHTML])

        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.setPushToken(uuid: "nnt_a", token: "tok-a")
        try await store.addKeyword(uuid: "nnt_a", keyword: "갤럭시")

        let apns = StubAPNs()
        let poller = PpomppuPoller(
            board: Self.board,
            store: store,
            apns: apns,
            fetcher: fetcher.fetch
        )
        await poller.tick()  // 첫 tick — sentinel 설정

        // page=1을 두 번째 페이지로 교체 (sentinel walk가 page=1부터 다시 fetch)
        await fetcher.replace(page: "1", html: secondHTML)
        // 410을 반환하도록 stub 변경
        await apns.setNextResult(.unregistered)

        await poller.tick()  // 두 번째 tick — 새 글 매칭 + push + 410 → NULL

        let sent = await apns.sentSnapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].deviceToken, "tok-a")
        XCTAssertTrue(sent[0].payload.aps.alert.body.contains("갤럭시 S25"))

        let storedToken = try await store.pushToken(uuid: "nnt_a")
        XCTAssertNil(storedToken, "410 응답이면 push_token=NULL")
    }

    /// 매칭 안 되는 새 글만 있으면 push 0건.
    func testNonMatchingPostsDoNotPush() async throws {
        let firstHTML = Self.minimalListHTML(rows: [(no: "100", title: "기존 글")])
        let secondHTML = Self.minimalListHTML(rows: [
            (no: "200", title: "키워드와 무관한 글"),
            (no: "100", title: "기존 글"),
        ])
        let fetcher = StubFetcher(pages: ["1": firstHTML])
        let store = try Store(path: ":memory:")
        defer { Task { await store.close() } }
        try await store.upsertUser(uuid: "nnt_a")
        try await store.setPushToken(uuid: "nnt_a", token: "tok-a")
        try await store.addKeyword(uuid: "nnt_a", keyword: "갤럭시")
        let apns = StubAPNs()
        let poller = PpomppuPoller(
            board: Self.board,
            store: store,
            apns: apns,
            fetcher: fetcher.fetch
        )
        await poller.tick()
        await fetcher.replace(page: "1", html: secondHTML)
        await poller.tick()
        XCTAssertEqual(await apns.sentCount, 0)
    }

    // MARK: - Fixtures

    /// PpomppuParser가 받아들이는 minimal HTML. 글 행 N개를 위에서 아래로(=신→구) 출력.
    private static func minimalListHTML(rows: [(no: String, title: String)]) -> String {
        var html = #"<html><body><ul class="bbsList_new">"#
        for row in rows {
            html += #"""
            <li class="">
                <a href="https://www.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=\#(row.no)"><strong>\#(row.title)</strong></a>
                <span class="rp">0</span>
                <time>10:00:00</time>
            </li>
            """#
        }
        html += "</ul></body></html>"
        return html
    }
}

// MARK: - Test-only actors / stubs

private actor StubFetcher {
    private var pages: [String: String]

    init(pages: [String: String]) { self.pages = pages }

    func replace(page: String, html: String) { pages[page] = html }

    /// `URLQueryItem` "page=N"에서 N을 키로 lookup. 첫 페이지(page param 없음)는 "1".
    nonisolated func fetch(url: URL, encoding: String.Encoding) async throws -> String {
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "page" })?
            .value ?? "1"
        return await self.lookup(page: page)
    }

    private func lookup(page: String) -> String {
        pages[page] ?? ""
    }
}

private actor StubAPNs: APNsSender {
    struct Sent {
        let deviceToken: String
        let payload: APNsPayload
    }
    private var sent: [Sent] = []
    private var nextResult: APNsResult = .ok

    func setNextResult(_ r: APNsResult) { nextResult = r }
    var sentCount: Int { sent.count }
    func sentSnapshot() -> [Sent] { sent }

    func send(deviceToken: String, payload: APNsPayload) async throws -> APNsResult {
        sent.append(Sent(deviceToken: deviceToken, payload: payload))
        return nextResult
    }
}
```

NOTE: `APNsSender` protocol은 Step 3에서 정의 (`APNsClient`도 채택하도록 추가).

- [ ] **Step 2: 실패 확인**

```bash
swift test --filter PpomppuPollerTests
```

Expected: `cannot find 'APNsSender' / 'PpomppuPoller' in scope`.

- [ ] **Step 3: APNsClient에 protocol 채택 추가**

`Server/Sources/NuntingServer/APNs/APNsClient.swift` 상단에 추가:
```swift
public protocol APNsSender: Sendable {
    func send(deviceToken: String, payload: APNsPayload) async throws -> APNsResult
}
```

그리고 `APNsClient` 선언을:
```swift
public actor APNsClient: APNsSender {
```
로 수정.

- [ ] **Step 4: PpomppuPoller 작성**

`Server/Sources/NuntingServer/Poller/PpomppuPoller.swift`:
```swift
import Foundation
import NuntingCore

/// 뽐뿌 게시판 폴러. 3분 주기로 tick.
///
/// 동작:
///  1) lastSeenPostId == nil이면 page=1만 페치해 top post.id를 sentinel로 저장하고 종료.
///  2) lastSeenPostId가 있으면 page=1부터 sentinel을 만날 때까지 또는 maxPages 까지 walk.
///  3) sentinel을 만나기 전까지의 글을 reverse(=시간순)로 매칭 + APNs send.
///  4) APNs 응답이 .unregistered면 store.setPushToken(uuid, nil)로 self-heal.
///  5) sentinel을 새 최신 글 id로 갱신.
///
/// 종속성은 외부 주입:
///  - fetcher: HTML fetch (테스트는 stub, 프로덕션은 ServerNetworking.fetchHTML)
///  - store: Store actor (구독자 스냅샷 + 410 처리)
///  - apns: APNsSender (테스트는 stub, 프로덕션은 APNsClient)
public actor PpomppuPoller {
    public typealias Fetcher = @Sendable (URL, String.Encoding) async throws -> String

    private let board: Board
    private let store: Store
    private let apns: APNsSender
    private let fetcher: Fetcher
    private let maxPages: Int

    private var lastSeenPostId: String?

    public init(
        board: Board,
        store: Store,
        apns: APNsSender,
        fetcher: @escaping Fetcher,
        maxPages: Int = 10
    ) {
        self.board = board
        self.store = store
        self.apns = apns
        self.fetcher = fetcher
        self.maxPages = maxPages
    }

    public func tick() async {
        do {
            try await tickThrowing()
        } catch {
            // 네트워크/파서 실패는 다음 tick에 다시 — 로깅만.
            // 운영에서는 stderr로 흐르고, 다중 연속 실패는 PR E의 health check가 잡는다.
            print("[PpomppuPoller] tick error: \(error)")
        }
    }

    private func tickThrowing() async throws {
        // 1) 첫 실행 — sentinel만 잡고 종료
        guard let sentinel = lastSeenPostId else {
            let posts = try await fetchAndParse(page: 1)
            lastSeenPostId = posts.first?.id
            return
        }

        // 2) sentinel walk
        var newPosts: [Post] = []
        outer: for page in 1...maxPages {
            let posts = try await fetchAndParse(page: page)
            if posts.isEmpty { break outer }
            for post in posts {
                if post.id == sentinel { break outer }
                newPosts.append(post)
            }
        }
        if newPosts.isEmpty { return }

        // 3) 오래된 것부터 send (push 도착 순서 정렬)
        newPosts.reverse()

        // 4) 구독자 스냅샷 + 매칭
        let subscriptions = try await store.usersWithKeywords()
        let userKeywords = subscriptions.mapValues { $0.keywords }
        let matches = KeywordMatcher.match(posts: newPosts, subscriptions: userKeywords)

        for m in matches {
            guard let sub = subscriptions[m.uuid] else { continue }
            let payload = APNsPayload(
                title: "뽐뿌 — \(m.keyword)",
                body: m.post.title,
                url: m.post.url
            )
            do {
                let result = try await apns.send(deviceToken: sub.pushToken, payload: payload)
                if case .unregistered = result {
                    try? await store.setPushToken(uuid: m.uuid, token: nil)
                }
            } catch {
                print("[PpomppuPoller] APNs send error for uuid=\(m.uuid): \(error)")
            }
        }

        // 5) sentinel 갱신 — newPosts.last가 newest (reverse 후)
        lastSeenPostId = newPosts.last?.id
    }

    private func fetchAndParse(page: Int) async throws -> [Post] {
        var components = URLComponents(string: "https://www.ppomppu.co.kr\(board.path)")!
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "page", value: "\(page)"))
        components.queryItems = queryItems
        let url = components.url!
        let html = try await fetcher(url, board.site.encoding)
        return try PpomppuParser().parseList(html: html, board: board)
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
swift test --filter PpomppuPollerTests
```

Expected: 3 tests passed.

- [ ] **Step 6: 커밋**

```bash
git add Server/Sources/NuntingServer/Poller/PpomppuPoller.swift Server/Sources/NuntingServer/APNs/APNsClient.swift Server/Tests/NuntingServerTests/PpomppuPollerTests.swift
git commit -m "feat(server): PpomppuPoller actor + sentinel walk + 매칭→push"
```

---

## Task 7: PollerService + main.swift 와이어

**Files:**
- Create: `Server/Sources/NuntingServer/Poller/PollerService.swift`
- Modify: `Server/Sources/NuntingServer/App.swift`
- Modify: `Server/Sources/NuntingServer/main.swift`

- [ ] **Step 1: PollerService 작성**

`Server/Sources/NuntingServer/Poller/PollerService.swift`:
```swift
import Foundation
import ServiceLifecycle

/// Hummingbird ServiceGroup이 SIGTERM 시 cancel 호출 → 루프가 종료.
/// `Service`는 swift-service-lifecycle의 프로토콜.
public struct PollerService: Service {
    private let poller: PpomppuPoller
    private let interval: Duration

    public init(poller: PpomppuPoller, interval: Duration = .seconds(180)) {
        self.poller = poller
        self.interval = interval
    }

    public func run() async throws {
        // 시작 직후 첫 tick (sentinel 잡기).
        await poller.tick()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch is CancellationError {
                return
            }
            await poller.tick()
        }
    }
}
```

- [ ] **Step 2: App.swift 시그니처 확장**

`Server/Sources/NuntingServer/App.swift` 전체 교체:
```swift
import Hummingbird
import ServiceLifecycle

/// 테스트는 `:memory:` Store + 빈 services를 주입한다.
/// main.swift는 디스크 Store + PollerService를 주입.
public func buildApp(
    store: Store,
    additionalServices: [any Service] = []
) -> some ApplicationProtocol {
    let router = Router(context: UserRequestContext.self)

    router.get("/health") { _, _ in "ok" }

    let authed = router.group("/me")
        .add(middleware: BearerMiddleware(store: store))
    authed.get("/_echo") { _, context in
        try context.requireUUID()
    }
    PushTokenRoutes(store: store).add(to: authed)
    KeywordRoutes(store: store).add(to: authed)

    return Application(
        router: router,
        configuration: .init(address: .hostname("127.0.0.1", port: 8080)),
        services: additionalServices
    )
}
```

- [ ] **Step 3: main.swift 와이어**

`Server/Sources/NuntingServer/main.swift` 전체 교체:
```swift
import Hummingbird
import Foundation
import NuntingCore

let env = ProcessInfo.processInfo.environment

// 1) DB
let dbPath = env["NUNTING_DB_PATH"] ?? "/var/lib/nunting/state.db"
let store = try Store(path: dbPath)

// 2) APNs (선택). dev에선 env 없으면 stub-print 모드로 폴백 — 폴러는 그래도 돈다.
let apns: any APNsSender = try makeAPNsSender(env: env)

// 3) Poller
let board = Board(
    id: "ppomppu",
    site: .ppomppu,
    name: "뽐뿌게시판",
    path: "/zboard/zboard.php?id=ppomppu"
)
let poller = PpomppuPoller(
    board: board,
    store: store,
    apns: apns,
    fetcher: { url, encoding in
        try await ServerNetworking.fetchHTML(url: url, encoding: encoding)
    }
)

let interval: Duration
if let raw = env["NUNTING_POLL_INTERVAL_SECONDS"], let s = Int(raw) {
    interval = .seconds(s)
} else {
    interval = .seconds(180)
}
let pollerService = PollerService(poller: poller, interval: interval)

// 4) Application
let app = buildApp(store: store, additionalServices: [pollerService])

do {
    try await app.runService()
    await store.close()
} catch {
    await store.close()
    throw error
}

// MARK: - APNs sender 구성

/// 4개 env(`APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC`) 모두
/// 있으면 실 APNsClient. 하나라도 누락이면 stub-print 모드(stderr 로그).
/// 1인 도구 + 비공개 배포라 sample creds 박지 않고 graceful degrade.
func makeAPNsSender(env: [String: String]) throws -> any APNsSender {
    guard
        let keyPath = env["APNS_KEY_PATH"],
        let keyId = env["APNS_KEY_ID"],
        let teamId = env["APNS_TEAM_ID"],
        let topic = env["APNS_TOPIC"]
    else {
        FileHandle.standardError.write(Data(
            "[main] APNS_* env 누락 — stub-print 모드로 폴러 진행\n".utf8
        ))
        return StubPrintAPNs()
    }
    let host = env["APNS_HOST"] ?? "api.sandbox.push.apple.com"
    let keyPEM = try String(contentsOfFile: keyPath, encoding: .utf8)
    let config = APNsConfig(
        keyPath: keyPath, keyId: keyId, teamId: teamId, topic: topic, host: host
    )
    return APNsClient(config: config, keyPEM: keyPEM) { url, headers, body in
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        let (respBody, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, respBody)
    }
}

/// 개발 환경용. 실제 APNs creds 없이도 매칭 흐름을 stderr로 관찰할 수 있다.
struct StubPrintAPNs: APNsSender {
    func send(deviceToken: String, payload: APNsPayload) async throws -> APNsResult {
        let log = "[APNs stub] token=\(deviceToken) title=\(payload.aps.alert.title) body=\(payload.aps.alert.body)"
        FileHandle.standardError.write(Data("\(log)\n".utf8))
        return .ok
    }
}
```

- [ ] **Step 4: 전체 테스트 통과 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift test
```

Expected: 모든 테스트 통과 (StoreTests 12 + BearerMiddlewareTests 3 + PushTokenRouteTests 4 + KeywordRoutesTests 10 + APNsJWTTests 1 + APNsClientTests 5 + KeywordMatcherTests 6 + PpomppuPollerTests 3 = 44).

- [ ] **Step 5: 커밋**

```bash
git add Server/Sources/NuntingServer/Poller/PollerService.swift Server/Sources/NuntingServer/App.swift Server/Sources/NuntingServer/main.swift
git commit -m "feat(server): PollerService + main.swift APNs/Poller 와이어"
```

---

## Task 8: 수동 smoke — 실제 뽐뿌 페치 + stub-print 모드

**Files:**
- (없음, 검증만)

목적: 실제 뽐뿌 페이지를 fetch + parse + 첫 tick에서 sentinel 잡기까지 동작하는지 확인. APNs 실제 전송은 별도 step에서 옵션.

- [ ] **Step 1: 서버 띄우기 — stub-print 모드**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
swift build
NUNTING_DB_PATH=/tmp/nunting-poller-smoke.db \
NUNTING_POLL_INTERVAL_SECONDS=20 \
swift run NuntingServer > /tmp/nunting-poller.log 2>&1 &
SERVER_PID=$!
sleep 5
```

- [ ] **Step 2: 로그에 stub-print fallback + 첫 tick 흔적 확인**

```bash
grep -E "(APNS_\* env 누락|listening on)" /tmp/nunting-poller.log
```

Expected:
```
[main] APNS_* env 누락 — stub-print 모드로 폴러 진행
... [HummingbirdCore] Server started and listening on 127.0.0.1:8080
```

만약 첫 줄이 없으면 main.swift의 graceful degrade가 깨진 것.

- [ ] **Step 3: HTTP /health 응답 확인 (poller가 살아있어도 HTTP 서비스는 정상 동작)**

```bash
curl -s http://127.0.0.1:8080/health
```

Expected: `ok`

- [ ] **Step 4: 키워드 등록 후 ~25초 대기 (2번째 tick)**

```bash
curl -s -X POST http://127.0.0.1:8080/me/keywords \
  -H "Authorization: Bearer nnt_smoke-poller" \
  -H "Content-Type: application/json" \
  -d '{"keyword":"무료"}'
echo
curl -s -X PUT http://127.0.0.1:8080/me/push-token \
  -H "Authorization: Bearer nnt_smoke-poller" \
  -H "Content-Type: application/json" \
  -d '{"token":"smoke-token-fake"}'
echo "registered, waiting 25s for second tick..."
sleep 25
```

키워드 "무료"는 뽐뿌 핫딜에서 흔히 매칭됨. 20초 간격 두 번째 tick에서 새 글이 있으면 stub-print 로그가 떠야 함.

- [ ] **Step 5: stub-print 로그 확인**

```bash
grep "APNs stub" /tmp/nunting-poller.log | head -20
```

Expected:
- 매칭 결과가 있으면 `[APNs stub] token=smoke-token-fake title=뽐뿌 — 무료 body=...` 줄들 출력
- 매칭 0건이면 위 grep이 비어도 OK (뽐뿌 글에 "무료"가 한 건도 없는 시점일 수 있음, 다른 흔한 단어로 재시도해도 무방)

만약 fetch/parse 실패 로그가 있으면 issue:
```bash
grep "tick error" /tmp/nunting-poller.log
```
Expected: 비어 있어야 함. tick error 발생 시 BLOCKED 보고.

- [ ] **Step 6: 서버 종료 + cleanup**

```bash
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null
sqlite3 /tmp/nunting-poller-smoke.db "SELECT uuid, push_token FROM users;"
rm -f /tmp/nunting-poller-smoke.db /tmp/nunting-poller.log
```

Expected: sqlite에 `nnt_smoke-poller|smoke-token-fake` row 확인.

- [ ] **Step 7: (옵션) 실제 APNs sandbox 전송**

사용자가 본인 Apple Developer account의 `.p8` key + 실 device token을 갖고 있다면 별도로:

```bash
APNS_KEY_PATH=~/Documents/AuthKey_XXXXXXXX.p8 \
APNS_KEY_ID=XXXXXXXX \
APNS_TEAM_ID=YYYYYYYY \
APNS_TOPIC=com.moonjm.nunting \
APNS_HOST=api.sandbox.push.apple.com \
NUNTING_DB_PATH=/tmp/nunting-apns-smoke.db \
swift run NuntingServer
```

별도 터미널에서 키워드 + 실 device token 등록 후 매칭 글이 뜨면 실 디바이스에 푸시 도착 확인. **PR D(iOS deep link)가 없어 알림 탭 동작은 아직 미검증.**

이 step은 사용자 환경에 따라 skip 가능. v1 PR C 마감 기준은 Step 1~6.

- [ ] **Step 8: (검증만 한 경우 추가 커밋 없음)**

Task 7까지의 커밋이 PR C의 최종 상태. 스모크 중 발견한 버그가 있으면 fix 후 별도 커밋.

---

## Self-Review

### Spec coverage check (`docs/superpowers/specs/2026-05-12-ppomppu-keyword-push-design.md` §마이그레이션 단계 3)

| 스펙 항목 | 다루는 Task |
|----------|-----------|
| `PpomppuPoller` actor | Task 6 |
| sentinel walk 알고리즘 | Task 6 |
| 첫 실행은 sentinel만 잡고 종료 | Task 6 (test 명시) |
| maxPages cap (10) | Task 6 |
| `KeywordMatcher` (사용자×키워드 N×M) | Task 3 |
| `APNsClient` HTTP/2 + JWT ES256 | Task 1+2 |
| JWT 1시간 캐시 | Task 2 (test 명시) |
| 429/500/503 backoff (최대 3회) | Task 2 (test 명시) |
| 410 → push_token = NULL | Task 6 (test 명시) |
| 푸시 페이로드 `{aps, url}` | Task 1 |
| 3분 폴링 cadence | Task 7 (default `.seconds(180)`) |
| `users.push_token IS NOT NULL` 사용자만 발송 | Task 4 |
| 정규화 매칭 (`Store.normalizedKeyword`와 동일) | Task 3 (`title.lowercased().contains`) |

### 비범위 (의도적, PR D/E)

- iOS AppDelegate / KeywordListView (PR D)
- Docker compose / Cloudflare Tunnel (PR E)
- APNs 실 전송 자동화 테스트 (수동 옵션 Step 7만)
- 키워드 통계 / 음소거 시간대 (스펙 §미해결)
- 멀티 보드 (스펙 §비목표)

### 타입 일관성

- `APNsSender` protocol → Task 6에서 도입, `APNsClient` (Task 2) 채택, `StubPrintAPNs` (Task 7) 채택, `StubAPNs` (Task 6 테스트) 채택 — 일관.
- `APNsResult.unregistered` → Task 1 정의, Task 2 사용, Task 6 분기, Task 7 stub 무관(`.ok`만 반환).
- `Store.UserSubscription` → Task 4 정의, Task 6 폴러에서 `subscriptions[uuid]?.pushToken` 접근.
- `KeywordMatcher.Match` → Task 3 정의, Task 6 폴러에서 `m.post, m.uuid, m.keyword` 접근.
- `PpomppuPoller.Fetcher` typealias → Task 6 정의, Task 7 main.swift에서 `ServerNetworking.fetchHTML` 어댑터로 주입.
- `Board.site.encoding` → NuntingCore의 `Site` enum 속성. 기존 코드 그대로 사용.

### Placeholder scan

- "TBD"/"...later"/"add validation" 등 없음. 모든 step에 실제 코드 또는 명령.
- Task 5(ServerNetworking)는 테스트 없음을 명시적으로 "테스트가 없는 이유" docstring으로 정당화 — placeholder가 아닌 의도된 minimal.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-13-plan3-poller-apns.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Plan 2와 동일 패턴. task별 fresh subagent + 사이사이 spec/quality review.

**2. Inline Execution** — 이 세션에서 직접 진행.

Which approach?
