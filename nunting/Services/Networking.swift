import Foundation

extension URL {
    /// Returns `https://<host>/<path>` when `self` is plain `http://`,
    /// otherwise returns `self` unchanged. Lets ATS-clean hosts load
    /// media (`<img>` / zoom viewer) without a global `NSAllowsArbitraryLoads`
    /// exception. Most of the image CDNs embedded in community-board posts
    /// (carisyou, tistory, etc.) serve the same path over HTTPS, so a
    /// blind upgrade is safe; callers that need the original scheme
    /// should not use this helper.
    var atsSafe: URL {
        guard scheme?.lowercased() == "http",
              var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)
        else { return self }
        comps.scheme = "https"
        return comps.url ?? self
    }
}

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

    /// Rewrites `http://` redirect targets to `https://` before URLSession
    /// follows them. Some upstream sites (observed on Clien when the guest
    /// session cookie is stale) issue a 30x with an `http://` Location, which
    /// App Transport Security then blocks and surfaces as "The resource could
    /// not be loaded because the App Transport Security policy requires the
    /// use of a secure connection." All boards we scrape serve HTTPS on the
    /// same host, so a blind upgrade is safe and avoids an ATS exception.
    private final class RedirectHTTPSUpgrader: NSObject, URLSessionTaskDelegate {
        // `session.data(for:)` (the async API) invokes this task-level
        // delegate method on the session's delegate when the session was
        // constructed with one — documented behaviour since iOS 15. Do not
        // "fix" this by migrating to per-task `URLSessionTaskDelegate`
        // arguments; we need the single shared upgrader to cover every
        // caller (`fetchHTML`, `postForm`, `resolveFinalURL`) without
        // touching each one.
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let url = request.url,
                  url.scheme?.lowercased() == "http",
                  var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else {
                completionHandler(request)
                return
            }
            comps.scheme = "https"
            guard let upgraded = comps.url else {
                completionHandler(request)
                return
            }
            var upgradedRequest = request
            upgradedRequest.url = upgraded
            completionHandler(upgradedRequest)
        }
    }

    private static let redirectUpgrader = RedirectHTTPSUpgrader()

    static let session: URLSession = {
        _ = sharedCache
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 15
        config.urlCache = sharedCache
        config.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: config, delegate: redirectUpgrader, delegateQueue: nil)
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

    /// Fire a best-effort `HEAD /` to every supported-site host so the
    /// shared `URLSession` opens a TLS + HTTP/2 connection pool entry
    /// per host. Subsequent real requests (list / detail fetches) reuse
    /// the pooled connection and skip the 300-700 ms TLS handshake that
    /// the perf log showed on the first access per host per session.
    ///
    /// All requests run in parallel on a detached `.utility` task, have
    /// a short 5-second timeout, and ignore errors — the worst case is
    /// the same cold handshake the app used to pay, not a regression.
    /// Call at app launch and on scenePhase `.active` transitions.
    nonisolated static func prewarmConnections(hosts: [URL] = Site.allCases.map(\.baseURL)) {
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for host in hosts {
                    group.addTask {
                        var request = URLRequest(url: host)
                        request.httpMethod = "HEAD"
                        request.timeoutInterval = 5
                        _ = try? await session.data(for: request)
                    }
                }
            }
        }
    }

    static func postForm(
        url: URL,
        parameters: [String: String],
        referer: URL? = nil,
        /// Override the outgoing `Content-Type` header for endpoints that
        /// expect a value not matching the URL-encoded body shape. The
        /// default is correct for normal form POSTs; only override when a
        /// server specifically branches on this header. See `DdanziParser`
        /// for the current caller that needs this.
        contentType: String = "application/x-www-form-urlencoded; charset=utf-8"
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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
