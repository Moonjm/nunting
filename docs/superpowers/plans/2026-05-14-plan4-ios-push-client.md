# Plan 4 — iOS Push Client (PR D) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** iOS 앱에서 키워드를 등록 + 푸시 권한 허용하면 서버(PR C 완성)가 발사한 APNs 푸시를 받아 탭하면 해당 글 상세로 deep link로 진입한다. PR D 마감 기준은 실 디바이스에서 푸시 한 발 도착 + 탭 → 상세 열림까지 e2e 검증.

**Architecture:**
- Keychain `nnt_<UUID>`를 디바이스별로 1개 발급(synchronizable 아님 — 1 디바이스 단일). 모든 서버 호출에 `Authorization: Bearer nnt_…` 헤더.
- `@UIApplicationDelegateAdaptor`로 AppDelegate를 SwiftUI에 붙여 `registerForRemoteNotifications` + `UNUserNotificationCenter.delegate`만 연결. 권한 요청은 앱 시작 시 안 하고 "첫 키워드 추가" 시점에 미룬다(스펙).
- `AlertSubscriptionService`가 4개 엔드포인트 클라이언트 + UUID 발급/저장. `HTTPRequester` protocol DI로 단위 테스트는 URLProtocol 없이 in-process stub.
- 푸시 도착 시 payload `url` + `aps.alert.body`를 `DetailOverlayController.present(url:title:)` (신규 메서드 추가)로 넘겨 기존 detail overlay 흐름 재사용.

**Tech Stack:**
- iOS 17+, SwiftUI + UIKit `@UIApplicationDelegateAdaptor`
- Foundation `URLSession` (서버 호출) + Security framework (Keychain)
- UserNotifications (APNs)
- XCTest

---

## File Structure

```
nunting/
├── nuntingApp.swift                                # 수정: @UIApplicationDelegateAdaptor 추가
├── AppDelegate.swift                               # 신규: registerForRemoteNotifications + delegate 연결
├── Services/
│   ├── AlertSubscriptionService.swift              # 신규: Keychain UUID + 4 endpoints
│   ├── NotificationDelegate.swift                  # 신규: UNUserNotificationCenterDelegate 구현
│   └── DetailOverlayController.swift               # 수정: present(url:title:) 메서드 추가
└── Views/
    ├── SideDrawer.swift                            # 수정: "알림 키워드" 항목 + NavigationLink
    └── KeywordListView.swift                       # 신규: 리스트 + 추가/삭제 + 권한 배너

nunting/Info.plist                                  # 수정: NSAppTransportSecurity (로컬 dev용)
nunting.xcodeproj/.../nunting.entitlements          # 수정: aps-environment

nuntingTests/
├── AlertSubscriptionServiceTests.swift             # 신규: 4 endpoint round-trip
└── KeychainUUIDStoreTests.swift                    # 신규: 발급/조회 idempotency
```

파일별 책임:
- `nuntingApp.swift`: `@UIApplicationDelegateAdaptor(AppDelegate.self)` 한 줄만 추가. 기존 audio/webp 셋업은 유지.
- `AppDelegate.swift`: `application(_:didFinishLaunchingWithOptions:)`에서 `UNUserNotificationCenter.current().delegate = NotificationDelegate.shared`. `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` → hex 변환 → `AlertSubscriptionService.shared.registerPushToken(_:)`. `didFailToRegister` 로깅.
- `Services/AlertSubscriptionService.swift`: `final class`. baseURL static let(하드코딩 — 사이드로드 1인 도구). `UUIDStore` protocol + `KeychainUUIDStore`(prod) + `InMemoryUUIDStore`(테스트). `HTTPRequester` protocol DI. 4개 메서드 + `clearPushToken()` + Keychain helper.
- `Services/NotificationDelegate.swift`: `UNUserNotificationCenterDelegate`. `willPresent` → `[.banner, .sound]`. `didReceive` → payload `url` 추출 → `DetailOverlayController.shared.present(url:title:)`.
- `Services/DetailOverlayController.swift`: `present(url: URL, title: String)` 메서드 추가 — URL host로 `Site.detect`, query `id`/`no`로 boardID/postNo 추출, minimal `Post` 빌드 후 기존 `show(_:)` 호출.
- `Views/SideDrawer.swift`: 기존 항목들 사이에 "알림 키워드" 추가, `NavigationLink(destination: KeywordListView())`.
- `Views/KeywordListView.swift`: `@State` 리스트 + textfield + 추가/삭제. `task` modifier에서 `service.listKeywords()`. 상단에 `UNUserNotificationCenter.getNotificationSettings`로 권한 상태 체크 → 거부 시 배너.
- `Info.plist`: `NSAppTransportSecurity.NSAllowsLocalNetworking = true` (시뮬레이터 → macOS 서버 dev용).
- `*.entitlements`: `aps-environment = development`.

각 task는 자기 파일에 집중 + 해당 단위 테스트.

---

## Task 1: AlertSubscriptionService + UUIDStore + tests

**Files:**
- Create: `nunting/Services/AlertSubscriptionService.swift`
- Create: `nuntingTests/AlertSubscriptionServiceTests.swift`
- Create: `nuntingTests/KeychainUUIDStoreTests.swift`

- [ ] **Step 1: 실패 테스트 — AlertSubscriptionServiceTests**

`nuntingTests/AlertSubscriptionServiceTests.swift`:
```swift
import XCTest
@testable import nunting

final class AlertSubscriptionServiceTests: XCTestCase {
    /// addKeyword → POST + 정규화 결과 echo. 서버 Plan 2가 `"galaxy s25"` 형태로 200 반환.
    func testAddKeywordReturnsNormalizedFromServer() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 201, body: #""galaxy s25""#)
        let uuidStore = InMemoryUUIDStore(value: "nnt_test")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: uuidStore
        )
        let normalized = try await service.addKeyword("  Galaxy S25  ")
        XCTAssertEqual(normalized, "galaxy s25")

        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.url?.absoluteString, "http://example.com/me/keywords")
        XCTAssertEqual(recorded?.httpMethod, "POST")
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "Authorization"), "Bearer nnt_test")
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8)
        XCTAssertTrue(body?.contains("Galaxy S25") == true)
    }

    /// listKeywords → GET → JSON array.
    func testListKeywordsParsesJSONArray() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 200, body: #"["apple","banana"]"#)
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        let listed = try await service.listKeywords()
        XCTAssertEqual(listed, ["apple", "banana"])
    }

    /// removeKeyword → DELETE /me/keywords/{encoded}.
    /// 한글 keyword가 URL-encoded되는지 검증.
    func testRemoveKeywordURLEncodesKeywordSegment() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 204, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        try await service.removeKeyword("갤럭시")
        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.httpMethod, "DELETE")
        XCTAssertTrue(
            recorded?.url?.absoluteString.contains("/me/keywords/%EA%B0%A4%EB%9F%AD%EC%8B%9C") == true,
            "한글 keyword segment가 percent-encoded돼야 함"
        )
    }

    /// registerPushToken → PUT body `{"token": "<hex>"}`.
    func testRegisterPushTokenSendsHexBody() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 204, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        let tokenData = Data([0xAA, 0xBB, 0xCC, 0xDD])
        try await service.registerPushToken(tokenData)
        let recorded = await stub.lastRequest()
        XCTAssertEqual(recorded?.httpMethod, "PUT")
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("\"token\":\"aabbccdd\""), "hex lowercased 4바이트")
    }

    /// clearPushToken → PUT body `{"token": null}`.
    /// iOS가 권한 회수 후 onAppear 등에서 호출. 서버는 push_token NULL 저장.
    func testClearPushTokenSendsNullBody() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 204, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        try await service.clearPushToken()
        let recorded = await stub.lastRequest()
        let body = String(data: recorded?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertEqual(body, #"{"token":null}"#)
    }

    /// 4xx 응답 시 throw — 호출자가 retry/UI 처리.
    func testNon2xxResponseThrows() async throws {
        let stub = StubHTTPRequester()
        await stub.setNext(status: 400, body: "")
        let service = AlertSubscriptionService(
            baseURL: URL(string: "http://example.com")!,
            requester: stub,
            uuidStore: InMemoryUUIDStore(value: "nnt_test")
        )
        do {
            _ = try await service.addKeyword("x")
            XCTFail("400 응답에서 throw해야 함")
        } catch is AlertSubscriptionError {
            // ok
        }
    }
}

// MARK: - Test stubs

actor StubHTTPRequester: HTTPRequester {
    private var nextStatus: Int = 200
    private var nextBody: Data = Data()
    private(set) var recorded: URLRequest?

    func setNext(status: Int, body: String) {
        self.nextStatus = status
        self.nextBody = body.data(using: .utf8) ?? Data()
    }
    func lastRequest() -> URLRequest? { recorded }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        recorded = request
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: nextStatus,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (nextBody, resp)
    }
}

struct InMemoryUUIDStore: UUIDStore {
    let value: String
    func getOrCreate() throws -> String { value }
}
```

- [ ] **Step 2: KeychainUUIDStoreTests 실패 테스트**

`nuntingTests/KeychainUUIDStoreTests.swift`:
```swift
import XCTest
@testable import nunting

final class KeychainUUIDStoreTests: XCTestCase {
    /// 같은 service+account 키로 두 번 호출하면 같은 UUID 반환(멱등).
    /// 실제 Keychain에 쓰므로 service 이름에 random suffix를 두고 tearDown에서 삭제.
    private let testService = "com.moonjm.nunting.test.\(UUID().uuidString)"

    override func tearDown() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService,
        ]
        SecItemDelete(q as CFDictionary)
        super.tearDown()
    }

    func testGetOrCreateReturnsSameValueOnRepeatedCalls() throws {
        let store = KeychainUUIDStore(service: testService, account: "uuid")
        let first = try store.getOrCreate()
        let second = try store.getOrCreate()
        XCTAssertEqual(first, second, "Keychain에 한 번 저장된 UUID는 멱등 조회돼야 함")
        XCTAssertTrue(first.hasPrefix("nnt_"))
    }

    func testGeneratedValueHasNNTPrefixAndUUIDBody() throws {
        let store = KeychainUUIDStore(service: testService, account: "uuid")
        let value = try store.getOrCreate()
        XCTAssertTrue(value.hasPrefix("nnt_"))
        let body = String(value.dropFirst("nnt_".count))
        XCTAssertNotNil(UUID(uuidString: body), "prefix 뒤는 UUID() 문자열")
    }
}
```

- [ ] **Step 3: 실패 확인**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting
xcodebuild test -project nunting.xcodeproj -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:nuntingTests/AlertSubscriptionServiceTests 2>&1 | tail -10
```

Expected: 컴파일 fail (`AlertSubscriptionService`, `HTTPRequester`, `UUIDStore` 등 미정의).

- [ ] **Step 4: AlertSubscriptionService.swift 작성**

`nunting/Services/AlertSubscriptionService.swift`:
```swift
import Foundation
import Security

// MARK: - Protocols (test seam)

protocol HTTPRequester: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPRequester {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

protocol UUIDStore {
    func getOrCreate() throws -> String
}

// MARK: - Errors

enum AlertSubscriptionError: Error {
    case http(status: Int, body: String)
    case decodeFailed(String)
}

// MARK: - Service

final class AlertSubscriptionService {
    /// 사이드로드 1인 도구라 hardcoded. 실 배포 전 본인 Cloudflare Tunnel
    /// 호스트로 교체(예: `https://nunting.YOUR-DOMAIN`). 시뮬레이터 dev는
    /// `http://127.0.0.1:8080` + Info.plist `NSAllowsLocalNetworking`.
    static let defaultBaseURL = URL(string: "http://127.0.0.1:8080")!

    static let shared = AlertSubscriptionService(
        baseURL: AlertSubscriptionService.defaultBaseURL,
        requester: URLSession.shared,
        uuidStore: KeychainUUIDStore()
    )

    private let baseURL: URL
    private let requester: HTTPRequester
    private let uuidStore: UUIDStore

    init(baseURL: URL, requester: HTTPRequester, uuidStore: UUIDStore) {
        self.baseURL = baseURL
        self.requester = requester
        self.uuidStore = uuidStore
    }

    // MARK: - Endpoints

    func registerPushToken(_ tokenData: Data) async throws {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        let body = #"{"token":"\#(hex)"}"#
        _ = try await put("/me/push-token", jsonBody: body)
    }

    func clearPushToken() async throws {
        _ = try await put("/me/push-token", jsonBody: #"{"token":null}"#)
    }

    func listKeywords() async throws -> [String] {
        let (data, _) = try await get("/me/keywords")
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw AlertSubscriptionError.decodeFailed(String(data: data, encoding: .utf8) ?? "")
        }
    }

    @discardableResult
    func addKeyword(_ raw: String) async throws -> String {
        let payload = ["keyword": raw]
        let body = try JSONEncoder().encode(payload)
        let (data, _) = try await post("/me/keywords", jsonBody: body)
        do {
            return try JSONDecoder().decode(String.self, from: data)
        } catch {
            throw AlertSubscriptionError.decodeFailed(String(data: data, encoding: .utf8) ?? "")
        }
    }

    func removeKeyword(_ keyword: String) async throws {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
        _ = try await delete("/me/keywords/\(encoded)")
    }

    // MARK: - HTTP helpers

    private func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        try await send(method: "GET", path: path, body: nil)
    }
    private func post(_ path: String, jsonBody: Data) async throws -> (Data, HTTPURLResponse) {
        try await send(method: "POST", path: path, body: jsonBody)
    }
    private func put(_ path: String, jsonBody: String) async throws -> (Data, HTTPURLResponse) {
        try await send(method: "PUT", path: path, body: jsonBody.data(using: .utf8))
    }
    private func delete(_ path: String) async throws -> (Data, HTTPURLResponse) {
        try await send(method: "DELETE", path: path, body: nil)
    }

    private func send(method: String, path: String, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let uuid = try uuidStore.getOrCreate()
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(uuid)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await requester.send(req)
        let http = resp as! HTTPURLResponse
        guard (200..<300).contains(http.statusCode) else {
            throw AlertSubscriptionError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return (data, http)
    }
}

// MARK: - KeychainUUIDStore

struct KeychainUUIDStore: UUIDStore {
    let service: String
    let account: String

    init(service: String = "com.moonjm.nunting.alert", account: String = "uuid") {
        self.service = service
        self.account = account
    }

    func getOrCreate() throws -> String {
        if let existing = read() { return existing }
        let value = "nnt_\(UUID().uuidString)"
        try write(value)
        return value
    }

    private func read() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String) throws {
        let data = value.data(using: .utf8)!
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // synchronizable = false (기본). iCloud 동기화 금지 — 디바이스 한 대만.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        // 이전 잔재 제거 후 add (atomic update 대용).
        SecItemDelete(q as CFDictionary)
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "KeychainUUIDStore",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Keychain add failed (status=\(status))"]
            )
        }
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

```bash
xcodebuild test -project nunting.xcodeproj -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:nuntingTests/AlertSubscriptionServiceTests -only-testing:nuntingTests/KeychainUUIDStoreTests 2>&1 | tail -15
```

Expected: 6 + 2 = 8 tests passed.

- [ ] **Step 6: 커밋**

```bash
git add nunting/Services/AlertSubscriptionService.swift nuntingTests/AlertSubscriptionServiceTests.swift nuntingTests/KeychainUUIDStoreTests.swift
git commit -m "feat(ios): AlertSubscriptionService — Keychain UUID + 4 endpoints"
```

---

## Task 2: AppDelegate + nuntingApp 와이어

**Files:**
- Create: `nunting/AppDelegate.swift`
- Modify: `nunting/nuntingApp.swift`

- [ ] **Step 1: AppDelegate 작성**

`nunting/AppDelegate.swift`:
```swift
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }

    /// APNs 등록 성공 — deviceToken을 hex로 변환해 서버에 PUT.
    /// 같은 토큰을 매번 PUT해도 서버는 idempotent UPDATE.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            do {
                try await AlertSubscriptionService.shared.registerPushToken(deviceToken)
            } catch {
                print("[AppDelegate] registerPushToken error: \(error)")
            }
        }
    }

    /// 권한 거부 / network 등 다양한 사유. 토큰 못 받았으니 서버에 null PUT.
    /// 다음에 사용자가 설정에서 켜고 앱 재시작하면 didRegisterForRemoteNotifications가
    /// 다시 호출되어 토큰 PUT.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] didFailToRegister: \(error)")
    }
}
```

- [ ] **Step 2: nuntingApp.swift 수정**

`nunting/nuntingApp.swift`의 `struct nuntingApp: App {` 직후에 한 줄 추가:

기존:
```swift
struct nuntingApp: App {
    init() {
```

수정:
```swift
struct nuntingApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
```

기존 init 본문과 body는 그대로 유지.

- [ ] **Step 3: 빌드 확인**

```bash
xcodebuild -project nunting.xcodeproj -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. NotificationDelegate가 아직 없으니 일단 type 미정의 에러가 날 수 있음 — Task 3 후 다시 빌드.

만약 NotificationDelegate 미정의 빌드 에러가 fail 차단이면 임시로 AppDelegate에서 `UNUserNotificationCenter.current().delegate = NotificationDelegate.shared` 줄을 주석 처리하고 Task 3 후 복원하거나, Task 3을 먼저 진행해도 무방.

- [ ] **Step 4: 커밋 — Task 3 같이 묶어 진행**

이 task의 commit은 Task 3 끝에 함께 한다(NotificationDelegate가 있어야 컴파일됨).

---

## Task 3: NotificationDelegate — willPresent + didReceive deep link

**Files:**
- Create: `nunting/Services/NotificationDelegate.swift`
- Modify: `nunting/Services/DetailOverlayController.swift`

- [ ] **Step 1: DetailOverlayController.present(url:title:) 추가**

`nunting/Services/DetailOverlayController.swift`의 `show(_ post: Post)` 메서드 근처에 추가(기존 `show`는 그대로 유지):

```swift
/// 푸시 알림의 deep-link payload(`url` + `aps.alert.body`)로 detail overlay 진입.
/// URL host로 site 추정 + query items로 boardID/postNo 추출 → minimal Post 빌드.
/// PostDetailLoader가 cold path로 실제 본문 fetch.
func present(url: URL, title: String) {
    guard let site = Site.detect(host: url.host) else { return }
    let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let queryItems = comps?.queryItems ?? []
    let boardID = queryItems.first(where: { $0.name == "id" })?.value ?? ""
    let postNo = queryItems.first(where: { $0.name == "no" })?.value ?? UUID().uuidString
    let post = Post(
        id: "\(boardID.isEmpty ? site.rawValue : boardID)-\(postNo)",
        site: site,
        boardID: boardID,
        title: title,
        author: "",
        date: nil,
        dateText: "",
        commentCount: 0,
        url: url
    )
    show(post)
}
```

NOTE: `Site.rawValue`가 NuntingCore Site enum에서 String이라 가정. 만약 raw type이 다르면 fallback id 빌더만 조정(예: `"deeplink-\(postNo)"`).

NOTE 2: `Post` 생성자가 보이는 필드 외에 viewCount/recommendCount/levelText/hasAuthIcon 옵셔널 default가 있을 수 있음. 빌드 에러 시 default 인자가 모두 있는지 확인. 없으면 minimal 인자 전체 명시.

- [ ] **Step 2: NotificationDelegate 작성**

`nunting/Services/NotificationDelegate.swift`:
```swift
import UserNotifications
import UIKit

/// UNUserNotificationCenter delegate.
/// `willPresent`: foreground 시에도 시스템 배너 + 사운드 — 커스텀 in-app 토스트 안 만듦.
/// `didReceive`: payload `url` 추출해 detail overlay 진입.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard let urlStr = userInfo["url"] as? String, let url = URL(string: urlStr) else { return }
        let title = response.notification.request.content.body
        Task { @MainActor in
            DetailOverlayController.shared.present(url: url, title: title)
        }
    }
}
```

NOTE: `DetailOverlayController.shared`가 `@MainActor` isolated일 가능성이 큼 — `Task { @MainActor in ... }`로 안전 호출.

- [ ] **Step 3: 빌드 확인**

```bash
xcodebuild -project nunting.xcodeproj -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: 커밋 (Task 2 + 3 묶어서)**

```bash
git add nunting/AppDelegate.swift nunting/nuntingApp.swift nunting/Services/NotificationDelegate.swift nunting/Services/DetailOverlayController.swift
git commit -m "feat(ios): AppDelegate + NotificationDelegate + deep-link URL→Post"
```

---

## Task 4: KeywordListView UI

**Files:**
- Create: `nunting/Views/KeywordListView.swift`

- [ ] **Step 1: KeywordListView 작성**

`nunting/Views/KeywordListView.swift`:
```swift
import SwiftUI
import UserNotifications
import UIKit

/// 키워드 리스트 + 추가/삭제. 첫 키워드 추가 시 푸시 권한 요청.
/// 권한 거부 시 상단 배너로 안내(키워드 저장은 가능, 알림은 안 옴).
struct KeywordListView: View {
    @State private var keywords: [String] = []
    @State private var newKeyword = ""
    @State private var errorMessage: String?
    @State private var pushAuthStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        List {
            if pushAuthStatus == .denied {
                Section {
                    permissionBanner
                }
            }
            Section("새 키워드") {
                HStack {
                    TextField("예: 갤럭시", text: $newKeyword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.done)
                        .onSubmit { Task { await submitNewKeyword() } }
                    Button("추가") { Task { await submitNewKeyword() } }
                        .disabled(newKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
            Section("등록됨") {
                if keywords.isEmpty {
                    Text("아직 키워드가 없습니다").foregroundStyle(.secondary)
                } else {
                    ForEach(keywords, id: \.self) { kw in
                        Text(kw)
                    }
                    .onDelete(perform: deleteKeywords)
                }
            }
        }
        .navigationTitle("알림 키워드")
        .task { await loadAll() }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("푸시 알림 권한이 꺼져 있습니다")
                .font(.subheadline.weight(.semibold))
            Text("키워드가 매칭돼도 알림이 도착하지 않습니다. 설정에서 켜주세요.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func loadAll() async {
        await refreshAuthStatus()
        do {
            keywords = try await AlertSubscriptionService.shared.listKeywords()
        } catch {
            errorMessage = "키워드 불러오기 실패: \(error.localizedDescription)"
        }
    }

    private func refreshAuthStatus() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        pushAuthStatus = s.authorizationStatus
    }

    private func submitNewKeyword() async {
        let raw = newKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        errorMessage = nil

        // 첫 키워드 추가 시 푸시 권한 요청. 이미 결정된 상태면 no-op.
        if pushAuthStatus == .notDetermined {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            await refreshAuthStatus()
            if granted {
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }

        do {
            let normalized = try await AlertSubscriptionService.shared.addKeyword(raw)
            newKeyword = ""
            if !keywords.contains(normalized) {
                keywords.append(normalized)
                keywords.sort()  // 서버도 정렬 응답
            }
        } catch {
            errorMessage = "추가 실패: \(error.localizedDescription)"
        }
    }

    private func deleteKeywords(at offsets: IndexSet) {
        let toDelete = offsets.map { keywords[$0] }
        keywords.remove(atOffsets: offsets)
        Task {
            for kw in toDelete {
                do {
                    try await AlertSubscriptionService.shared.removeKeyword(kw)
                } catch {
                    errorMessage = "삭제 실패(\(kw)): \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        KeywordListView()
    }
}
```

- [ ] **Step 2: 빌드 확인**

```bash
xcodebuild -project nunting.xcodeproj -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: 커밋**

```bash
git add nunting/Views/KeywordListView.swift
git commit -m "feat(ios): KeywordListView — 리스트/추가/삭제 + 권한 배너"
```

---

## Task 5: SideDrawer hook

**Files:**
- Modify: `nunting/Views/SideDrawer.swift`

- [ ] **Step 1: SideDrawer에 "알림 키워드" 항목 추가**

먼저 기존 SideDrawer 구조를 확인:
```bash
head -100 nunting/Views/SideDrawer.swift
```

기존 항목들이 `Button` / `NavigationLink` / `Section` 어떤 패턴이든 동일 패턴으로 한 줄 추가. 예시(SideDrawer가 `NavigationLink`를 갖는 List 또는 VStack이라고 가정):

```swift
// 기존 사이드 메뉴 항목들 사이 또는 끝에 추가
NavigationLink(destination: KeywordListView()) {
    Label("알림 키워드", systemImage: "bell.badge")
}
```

만약 SideDrawer가 Button → state 변경으로 sheet 띄우는 패턴이면, KeywordListView도 같은 sheet/cover 흐름으로 push.

NOTE: 정확한 추가 위치는 implementer가 기존 항목 정렬 일관성에 맞춰 결정. 본 task는 한 항목 추가가 책임 — 다른 항목 순서 재배치는 하지 말 것.

- [ ] **Step 2: 빌드 + 시뮬레이터에서 시각 확인(선택)**

```bash
xcodebuild -project nunting.xcodeproj -scheme nunting -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`.

시뮬레이터로 앱 실행 후 사이드 드로어 열어 "알림 키워드" 항목이 표시되고 탭하면 KeywordListView로 push되는지 확인.

- [ ] **Step 3: 커밋**

```bash
git add nunting/Views/SideDrawer.swift
git commit -m "feat(ios): SideDrawer에 알림 키워드 항목 추가"
```

---

## Task 6: Info.plist + entitlements (수동 Xcode 설정 가이드)

**Files:**
- Modify: `nunting/Info.plist` (또는 Xcode target settings)
- Modify: `nunting.entitlements`

코드 변경 없이 Xcode 프로젝트 설정. Xcode GUI 단계를 텍스트로 명시.

- [ ] **Step 1: ATS 예외 (시뮬레이터 dev용)**

Xcode → Project Navigator → nunting → Info → URL Types/Custom iOS Target Properties:

`NSAppTransportSecurity` (Dictionary)에 다음 추가:
- `NSAllowsLocalNetworking` = `YES` (Boolean)

또는 직접 Info.plist 편집(파일 위치는 target 설정에 따라 다름 — Xcode가 자동 관리하면 보통 target settings):

```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

이 설정은 시뮬레이터에서 `http://127.0.0.1:8080`(macOS 서버)을 hit하기 위함. 실 디바이스 배포 시 Cloudflare Tunnel `https://`를 쓰면 이 예외와 무관.

- [ ] **Step 2: Push Notifications capability 추가**

Xcode → Project Navigator → nunting target → Signing & Capabilities 탭:
- `+ Capability` 버튼 → `Push Notifications` 선택

이 단계가 자동으로:
- `nunting.entitlements` 파일을 생성/수정해 `aps-environment = development` 추가
- Provisioning profile에 Push Notifications capability를 활성화

확인:
- Xcode → Signing & Capabilities → Push Notifications 카드가 보임
- `Build Settings` → `Code Signing Entitlements`가 entitlements 파일을 가리킴

- [ ] **Step 3: Apple Developer Portal 확인**

Apple Developer Portal(https://developer.apple.com/account)에서:
- Certificates, Identifiers & Profiles → Identifiers → 본 앱 Bundle ID 선택
- Capabilities에서 `Push Notifications` 체크박스 활성화 확인

PR C에서 이미 `.p8` Auth Key를 발급했다면 이미 활성화돼 있을 가능성이 큼. 새로 enable한 경우 provisioning profile 재발급(`xcode automatically manage signing`이면 자동).

- [ ] **Step 4: 커밋**

Info.plist 또는 entitlements 변경은 Xcode가 자동 처리 — `git status`로 변경된 파일 확인 후 커밋:

```bash
git status --short
git add <changed-files>
git commit -m "build(ios): NSAllowsLocalNetworking + Push Notifications capability"
```

만약 ATS/entitlements가 이미 한 commit 이전에 다른 이유로 설정돼 있다면 변경이 없을 수 있음 — 그 경우 커밋 skip.

---

## Task 7: 실 디바이스 e2e smoke

**Files:** (없음 — 검증만)

목적: PR D 마감 기준 = 실 디바이스에 푸시 한 발 도착 + 탭 → 글 열림까지 e2e 동작 확인.

준비물:
- 실 iPhone (Apple ID 로그인 + Xcode와 trust 관계 셋업)
- macOS에서 PR C 서버를 실 APNs creds로 띄움(또는 stub 모드)
- 본인 Cloudflare Tunnel 호스트(또는 LAN 노출 + simulator)

- [ ] **Step 1: AlertSubscriptionService baseURL 본인 환경에 맞게 수정**

`nunting/Services/AlertSubscriptionService.swift`의 `defaultBaseURL`을:
- 실 디바이스 → 본인 Cloudflare Tunnel 호스트(예: `https://nunting.YOUR.example.com`)
- 시뮬레이터 + 같은 Mac에서 서버 → `http://127.0.0.1:8080`

```swift
static let defaultBaseURL = URL(string: "https://YOUR-HOST")!
```

- [ ] **Step 2: 서버 띄우기 (실 APNs creds)**

```bash
cd /Users/youngminmoon/Documents/moonjm/nunting/Server
APNS_KEY_PATH=~/Documents/AuthKey_XXXXXXXX.p8 \
APNS_KEY_ID=XXXXXXXX \
APNS_TEAM_ID=YYYYYYYY \
APNS_TOPIC=com.moonjm.nunting \
APNS_HOST=api.sandbox.push.apple.com \
NUNTING_DB_PATH=/tmp/nunting-pr-d-smoke.db \
NUNTING_POLL_INTERVAL_SECONDS=30 \
swift run NuntingServer
```

- [ ] **Step 3: 실 디바이스에 빌드 + 실행**

Xcode → Run destination을 본인 iPhone으로 선택 → Run (⌘R).

앱이 디바이스에 설치되고 launch.

- [ ] **Step 4: 사이드 드로어 → 알림 키워드 → 첫 키워드 추가**

- 앱에서 사이드 드로어 열기
- "알림 키워드" 탭
- 텍스트필드에 "무료" 입력 → 추가
- iOS 권한 다이얼로그 뜨면 "허용" 선택

이 시점에 서버 로그에서:
```
PUT /me/push-token  → 204
POST /me/keywords  → 201
```

확인 가능해야 함.

- [ ] **Step 5: 서버 폴러가 매칭되는 새 글을 찾을 때까지 대기**

뽐뿌 글에 "무료" 키워드가 흔하므로 보통 30초~수분 안에 매칭. 서버 로그에서:
```
(APNs HTTP/2 send: status=200)  // 또는 stub-print 줄
```

확인.

- [ ] **Step 6: 디바이스에 푸시 도착 확인**

- 디바이스 lock screen 또는 알림 센터에 푸시 배너 표시
- 제목: `뽐뿌 — 무료`
- 본문: 매칭된 글 제목

- [ ] **Step 7: 푸시 탭 → 글 상세 열림 확인**

- 알림 탭
- 앱이 foreground로 와서 DetailOverlayController가 띄워짐
- 매칭된 글 본문이 로드되어 표시

만약 fail(앱 열리지만 상세 안 보임 / 빈 화면 등):
- Xcode 콘솔에서 `[NotificationDelegate]` 또는 `DetailOverlayController` 관련 로그 확인
- `userInfo["url"]` 추출이 됐는지
- `Site.detect`가 nil 반환했는지(host 매칭 실패)

- [ ] **Step 8: SQLite 검증(선택)**

```bash
sqlite3 /tmp/nunting-pr-d-smoke.db "SELECT uuid, push_token FROM users;"
sqlite3 /tmp/nunting-pr-d-smoke.db "SELECT uuid, keyword FROM keyword_subs;"
```

Expected: device의 실제 APNs hex token이 들어있음 + "무료" 키워드.

- [ ] **Step 9: cleanup**

```bash
# 서버 종료
# DB는 본인 운영 환경이면 그대로 / smoke만이면 삭제
rm -f /tmp/nunting-pr-d-smoke.db
```

baseURL을 실 운영용으로 두든 dev용 127.0.0.1로 되돌리든 본인 워크플로에 맞게.

- [ ] **Step 10: smoke 통과 시 추가 커밋 없음**

Task 1~6의 커밋이 PR D의 최종 상태. 만약 smoke 중 발견한 버그(예: URL 파싱이 PpomppuParser id 형식과 어긋남) 있으면 fix 후 별도 커밋.

baseURL을 본인 운영 호스트로 영구 설정한 경우 그 commit은 별도 PR(또는 PR E 운영가이드)에서 처리하는 게 깔끔.

---

## Self-Review

### Spec coverage check (`docs/superpowers/specs/2026-05-12-ppomppu-keyword-push-design.md` §iOS 측 변경 지점)

| 스펙 항목 | 다루는 Task |
|----------|-----------|
| `@UIApplicationDelegateAdaptor` 도입 | Task 2 |
| `UNUserNotificationCenter.delegate = self` | Task 2 (delegate에는 NotificationDelegate, Task 3) |
| 권한 요청을 첫 키워드 추가 시점에 | Task 4 (`submitNewKeyword`의 `notDetermined` 가드) |
| `registerForRemoteNotifications()` | Task 4 (권한 granted 후) |
| `didRegisterForRemoteNotificationsWithDeviceToken` → hex + 서버 PUT | Task 2 |
| `SideDrawer` "알림 키워드" 항목 | Task 5 |
| `KeywordListView` 리스트 + 추가/삭제 | Task 4 |
| `AlertSubscriptionService` 4 endpoints | Task 1 |
| `willPresent` foreground 배너 | Task 3 |
| `didReceive` URL → deep link | Task 3 |
| Keychain UUID (synchronizable false) | Task 1 |
| 권한 거부 시 키워드 저장 OK + 안내 배너 | Task 4 (permission banner) |
| 실 디바이스 e2e 검증 | Task 7 |

### 비범위 (의도적)

- 키워드 통계 / 음소거 시간대 (스펙 §미해결)
- 멀티 디바이스 (스펙 §iCloud 다른 디바이스: 본 PR은 1 디바이스만 고정)
- 폴러 모니터링 / health check (PR E)

### 타입 일관성

- `HTTPRequester` protocol — Task 1 정의, `URLSession`이 채택, `StubHTTPRequester` 테스트 stub.
- `UUIDStore` protocol — Task 1, `KeychainUUIDStore`(prod) + `InMemoryUUIDStore`(test) 채택.
- `AlertSubscriptionService.shared` static — Task 1 정의, Task 2 AppDelegate + Task 4 KeywordListView에서 사용.
- `NotificationDelegate.shared` — Task 3 정의, Task 2 AppDelegate에서 참조.
- `DetailOverlayController.present(url:title:)` — Task 3에서 추가, Task 3 NotificationDelegate.didReceive에서 호출.

### Placeholder scan

- "TBD"/"...later" 없음.
- Task 5의 "기존 항목 정렬 일관성에 맞춰 결정"은 implementer judgment 영역 — SideDrawer의 실제 구조를 plan 작성 시 깊게 파지 않은 부분. plan 작성자가 trade-off로 implementer에게 위임함을 명시.

### Known concerns

- `Post` 생성자 인자 default 여부 불확실 — Task 3 NOTE에 빌드 에러 시 조정 명시.
- `Site.rawValue` String 가정 — Task 3 NOTE에 fallback 명시.
- Xcode/iOS 시뮬레이터 정확한 디바이스 이름 (`iPhone 16`)은 사용자 환경에 따라 다를 수 있음 — `xcrun simctl list devices`로 확인 후 조정.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-14-plan4-ios-push-client.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Plan 2/3와 동일 패턴.

**2. Inline Execution** — 이 세션에서 직접 진행.

Which approach?
