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

    /// KeywordListView가 `error.localizedDescription`을 그대로 사용자에게 보여주므로
    /// case enum 이름 대신 의미 있는 문자열을 제공.
    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "서버 오류 (HTTP \(status))" : "서버 오류 (HTTP \(status)): \(trimmed)"
        case .decodeFailed(let raw):
            return "응답 디코드 실패: \(raw)"
        }
    }
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
        // `appendingPathComponent`은 이미 percent-encoded된 segment를 다시
        // encode해 `%25EA…` 형태로 깨뜨림. baseURL absoluteString + path를
        // 직접 합쳐 percent-encoded 결과를 그대로 유지.
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: base + normalizedPath) else {
            throw AlertSubscriptionError.http(status: -1, body: "invalid url: \(base)\(normalizedPath)")
        }
        var req = URLRequest(url: url)
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
