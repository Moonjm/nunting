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
