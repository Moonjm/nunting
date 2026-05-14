import Foundation

public protocol APNsSender: Sendable {
    func send(deviceToken: String, payload: APNsPayload) async throws -> APNsResult
}

/// APNs HTTP/2 provider 클라이언트. JWT 1시간 캐시 + 429/500/503 backoff
/// 재시도(최대 3회). 다른 상태 코드는 즉시 결과로 변환.
///
/// 테스트는 `HTTPRequester` closure로 in-process stub을 주입한다.
/// 프로덕션은 `URLSession.shared`을 감싸는 closure를 main.swift에서 주입.
public actor APNsClient: APNsSender {
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
        // PushTokenRoute는 256자 sanity cap만 두고 형식 검증은 안 한다(1인 도구 신뢰
        // 모델). path-unsafe 문자가 들어오면 URL 빌드가 실패할 수 있으므로 force unwrap
        // 대신 guard로 즉시 .fail로 변환.
        guard let url = URL(string: "https://\(config.host)/3/device/\(deviceToken)") else {
            return .fail(status: 0, body: "invalid device token format")
        }

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
