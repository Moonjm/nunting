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

enum AlertSubscriptionError: LocalizedError {
    case http(status: Int, body: String)
    case decodeFailed(String)
    case nonHTTPResponse
    case invalidURL(String)

    /// KeywordListView가 `error.localizedDescription`을 그대로 사용자에게 보여주므로
    /// case enum 이름 대신 의미 있는 문자열을 제공.
    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "서버 오류 (HTTP \(status))" : "서버 오류 (HTTP \(status)): \(trimmed)"
        case .decodeFailed(let raw):
            return "응답 디코드 실패: \(raw)"
        case .nonHTTPResponse:
            return "서버 응답 형식 오류"
        case .invalidURL(let url):
            return "잘못된 URL 형식: \(url)"
        }
    }
}

// MARK: - Models

/// 서버 `/me/alert-history` 응답의 한 건. 키 이름은 서버 Go `AlertHistoryItem`
/// (snake_case) 과 합의됨. `read` 는 글을 열어 읽음 처리됐는지 여부.
struct AlertHistoryItem: Decodable, Identifiable {
    let id: Int
    let keyword: String
    let postNo: String
    let title: String
    let url: String
    let sentAt: TimeInterval  // Unix seconds
    var read: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case keyword
        case postNo = "post_no"
        case title
        case url
        case sentAt = "sent_at"
        case read
    }

    var sentDate: Date { Date(timeIntervalSince1970: sentAt) }
}

/// 한 구독 행: 포함 키워드(CSV AND 토큰)와 제외 단어(CSV OR 토큰). 서버 Go
/// `KeywordSub` (keyword/exclude) 와 합의된 형태. `exclude == ""` 면 제외 없음.
/// `id` 는 포함 키워드(행 PK) — 같은 글에 대한 ForEach/upsert 식별자.
struct KeywordSub: Codable, Hashable, Identifiable {
    let keyword: String
    let exclude: String
    var id: String { keyword }
}

// MARK: - Service

final class AlertSubscriptionService {
    /// 사이드로드 1인 도구라 hardcoded. Cloudflare Tunnel 로 외부 노출 중.
    /// 변경 시 앱 재빌드 + 재설치 (Keychain UUID 는 유지되므로 서버 측 user 동일성 유지).
    static let defaultBaseURL = URL(string: "https://nnt.eunji.shop")!

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

    func listKeywords() async throws -> [KeywordSub] {
        let (data, _) = try await get("/me/keywords")
        do {
            return try JSONDecoder().decode([KeywordSub].self, from: data)
        } catch {
            throw AlertSubscriptionError.decodeFailed(String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// 포함 키워드 행을 추가하거나, 같은 `keyword` 면 그 행의 제외 단어를 갱신
    /// (서버 upsert). `keyword`/`exclude` 둘 다 raw 로 보내고 서버가 정규화한
    /// 결과(`KeywordSub`)를 돌려준다. 행 편집(제외 수정)도 이 메서드로.
    @discardableResult
    func upsertKeyword(keyword: String, exclude: String) async throws -> KeywordSub {
        let payload = ["keyword": keyword, "exclude": exclude]
        let body = try JSONEncoder().encode(payload)
        let (data, _) = try await post("/me/keywords", jsonBody: body)
        do {
            return try JSONDecoder().decode(KeywordSub.self, from: data)
        } catch {
            throw AlertSubscriptionError.decodeFailed(String(data: data, encoding: .utf8) ?? "")
        }
    }

    func removeKeyword(_ keyword: String) async throws {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? keyword
        _ = try await delete("/me/keywords/\(encoded)")
    }

    /// 서버가 기록한 키워드 매칭 이력을 최신순으로 가져온다. 매칭/푸시 발송은
    /// 전부 서버에서 일어나므로(클라는 푸시를 받을 뿐) 이력의 source of truth 도 서버.
    func fetchAlertHistory(limit: Int = 200) async throws -> [AlertHistoryItem] {
        let (data, _) = try await get("/me/alert-history?limit=\(limit)")
        do {
            return try JSONDecoder().decode([AlertHistoryItem].self, from: data)
        } catch {
            throw AlertSubscriptionError.decodeFailed(String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// 알림 한 건을 읽음 처리(서버 read_at set). 행 탭 → 글 열기 시 호출.
    func markAlertRead(id: Int) async throws {
        _ = try await post("/me/alert-history/\(id)/read", jsonBody: Data())
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
        let req = try makeRequest(method: method, path: path, body: body)
        let (data, resp) = try await requester.send(req)
        let http = try validate(response: resp, data: data)
        return (data, http)
    }

    private func makeRequest(method: String, path: String, body: Data?) throws -> URLRequest {
        let uuid = try uuidStore.getOrCreate()
        let url = try makeURL(path: path)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(uuid)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func makeURL(path: String) throws -> URL {
        // `appendingPathComponent`은 이미 percent-encoded된 segment를 다시
        // encode해 `%25EA…` 형태로 깨뜨림. baseURL absoluteString + path를
        // 직접 합쳐 percent-encoded 결과를 그대로 유지.
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base + normalizedPath) else {
            throw AlertSubscriptionError.invalidURL("\(base)\(normalizedPath)")
        }
        return url
    }

    private func validate(response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw AlertSubscriptionError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AlertSubscriptionError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return http
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
