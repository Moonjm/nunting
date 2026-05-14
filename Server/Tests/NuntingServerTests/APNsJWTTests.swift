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
