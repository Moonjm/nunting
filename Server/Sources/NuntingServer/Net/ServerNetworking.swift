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
