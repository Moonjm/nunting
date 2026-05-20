import Foundation
import SDWebImage

/// SDWebImage downloader operation that rewrites `http://` redirect
/// Locations to `https://` before URLSession follows them.
///
/// ATS blocks `https → 302 → http` chains by default — Korean board image
/// CDNs frequently 302 through legacy `getfile.php` proxies that emit a
/// cleartext Location even when the final origin is reachable over HTTPS
/// (observed: fmkorea getfile → ext.fmkorea.com → plaync.co.kr; aagag
/// 65G 댓글의 GIF). `URL.atsSafe` only upgrades source URLs; this hook
/// extends the same upgrade to redirect targets so the chain survives.
///
/// If the target really doesn't support HTTPS, the upgraded request fails
/// fast at the TLS handshake — same end-user outcome as the ATS block
/// (placeholder + retry button) with clearer logs.
final class HTTPSRedirectingDownloaderOperation: SDWebImageDownloaderOperation {
    // Explicit @objc selector pinning — Swift auto-bridges
    // `urlSession(_:task:...)` to ObjC selector `urlSession:task:...`
    // (소문자 u), but SDWebImage's downloader dispatches the redirect
    // callback via the literal `URLSession:task:...` (대문자 URL) selector.
    // Without the explicit `@objc(...)` Swift's override registers our
    // method under the lowercase selector, the base class's uppercase
    // selector gets shadowed/removed, and the runtime fires
    // "unrecognized selector sent to instance" on first redirect.
    @objc(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    override func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let rewritten = Self.upgradeHTTPToHTTPS(request)
        super.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: rewritten,
            completionHandler: completionHandler
        )
    }

    /// Returns the request with `http://` upgraded to `https://`; any other
    /// scheme passes through unchanged. Headers/body/method are preserved.
    /// Static so tests can exercise the rewrite without spinning up an
    /// SDWebImage downloader.
    static func upgradeHTTPToHTTPS(_ request: URLRequest) -> URLRequest {
        guard let url = request.url,
              url.scheme?.lowercased() == "http",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return request }
        comps.scheme = "https"
        guard let upgraded = comps.url else { return request }
        var newReq = request
        newReq.url = upgraded
        return newReq
    }
}
