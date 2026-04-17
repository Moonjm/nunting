import Foundation

enum NetworkError: Error, LocalizedError {
    case badResponse(Int)
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): "HTTP \(code)"
        case .decodingFailed: "응답 디코딩 실패"
        }
    }
}

struct Networking {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    static func fetchHTML(url: URL, encoding: String.Encoding = .utf8) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetworkError.badResponse(http.statusCode)
        }
        guard let html = String(data: data, encoding: encoding) else {
            throw NetworkError.decodingFailed
        }
        return html
    }
}
