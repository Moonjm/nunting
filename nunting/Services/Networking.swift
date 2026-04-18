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

    static let sharedCache: URLCache = {
        let cache = URLCache(
            memoryCapacity: 50 * 1024 * 1024,
            diskCapacity: 200 * 1024 * 1024,
            directory: nil
        )
        URLCache.shared = cache
        return cache
    }()

    static let session: URLSession = {
        _ = sharedCache
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 15
        config.urlCache = sharedCache
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config)
    }()

    static func fetchHTML(url: URL, encoding: String.Encoding = .utf8) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetworkError.badResponse(http.statusCode)
        }
        if let html = String(data: data, encoding: encoding) {
            return html
        }
        if encoding == .utf8 {
            return String(decoding: data, as: UTF8.self)
        }
        // Legacy-encoding lossy fallback: walk bytes and replace any sequence the
        // strict decoder rejected with U+FFFD so the user sees a partial page
        // instead of a hard failure (e.g. truncated CP949 multi-byte at EOF).
        return lossyDecode(data: data, encoding: encoding)
    }

    private static func lossyDecode(data: Data, encoding: String.Encoding) -> String {
        // Try chunks separated by ASCII boundaries; replace failed chunks with U+FFFD.
        var output = ""
        var idx = data.startIndex
        var pending = Data()

        func flush(_ buf: inout Data) {
            guard !buf.isEmpty else { return }
            if let s = String(data: buf, encoding: encoding) {
                output.append(s)
            } else {
                output.append("\u{FFFD}")
            }
            buf.removeAll(keepingCapacity: true)
        }

        while idx < data.endIndex {
            let byte = data[idx]
            if byte < 0x80 {
                // ASCII boundary — flush accumulated multibyte run, then append ASCII directly.
                flush(&pending)
                output.append(Character(UnicodeScalar(byte)))
            } else {
                pending.append(byte)
            }
            idx = data.index(after: idx)
        }
        flush(&pending)
        return output
    }

    static func postForm(url: URL, parameters: [String: String], referer: URL? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            if let scheme = referer.scheme, let host = referer.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }

        var comps = URLComponents()
        comps.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            #if DEBUG
            let preview = String(data: data.prefix(256), encoding: .utf8) ?? "<binary>"
            print("[Networking.postForm] HTTP \(http.statusCode) for \(url.absoluteString): \(preview)")
            #endif
            throw NetworkError.badResponse(http.statusCode)
        }
        return data
    }
}
