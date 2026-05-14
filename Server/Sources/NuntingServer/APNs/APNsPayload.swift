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
