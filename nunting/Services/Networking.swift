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
    /// Desktop UA for endpoints that serve a JS-redirect to mobile when given
    /// a mobile UA (e.g. ppomppu's `www.` host).
    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

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

    static func fetchHTML(
        url: URL,
        encoding: String.Encoding = .utf8,
        userAgent: String? = nil,
        handlesCookies: Bool = true
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = handlesCookies
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        if !handlesCookies {
            request.setValue("", forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetworkError.badResponse(http.statusCode)
        }
        return decodeHTML(data: data, encoding: encoding)
    }

    /// Strict-then-lossy decode shared with the redirect-resolver path that
    /// reuses an already-fetched body to avoid a second round-trip.
    static func decodeHTML(data: Data, encoding: String.Encoding) -> String {
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

    struct ResolvedRedirect {
        let url: URL
        /// When non-nil, the body fetched while discovering the URL — return it
        /// to the caller so they don't have to re-fetch the same URL.
        let prefetchedBody: Data?
    }

    /// Resolve a URL by following redirects with HEAD (cheap) and falling back
    /// to GET (which captures the body so it can be reused). Returns the
    /// original URL with no body on total failure.
    static func resolveFinalURL(_ url: URL) async -> ResolvedRedirect {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10
        if let (_, response) = try? await session.data(for: request),
           let final = response.url, final != url {
            return ResolvedRedirect(url: final, prefetchedBody: nil)
        }
        // Some endpoints reject HEAD or return 200 without redirecting; fall
        // back to GET. We capture `data` so callers can decode it directly
        // instead of re-fetching the same URL.
        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        get.timeoutInterval = 10
        if let (data, response) = try? await session.data(for: get),
           let final = response.url {
            return ResolvedRedirect(url: final, prefetchedBody: data)
        }
        return ResolvedRedirect(url: url, prefetchedBody: nil)
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
