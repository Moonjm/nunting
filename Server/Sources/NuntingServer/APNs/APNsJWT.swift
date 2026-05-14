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
