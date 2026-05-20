import XCTest
@testable import nunting

final class HTTPSRedirectingDownloaderOperationTests: XCTestCase {
    func testUpgradesHTTPToHTTPS() {
        let url = URL(string: "http://ext.fmkorea.com/getfile.php?code=abc&file=x%2Fy")!
        let out = HTTPSRedirectingDownloaderOperation.upgradeHTTPToHTTPS(URLRequest(url: url))
        XCTAssertEqual(
            out.url?.absoluteString,
            "https://ext.fmkorea.com/getfile.php?code=abc&file=x%2Fy",
            "scheme upgraded in-place, query string preserved verbatim"
        )
    }

    func testLeavesHTTPSUnchanged() {
        let url = URL(string: "https://i.namu.wiki/i/x.webp?v=1")!
        let out = HTTPSRedirectingDownloaderOperation.upgradeHTTPToHTTPS(URLRequest(url: url))
        XCTAssertEqual(out.url?.absoluteString, "https://i.namu.wiki/i/x.webp?v=1")
    }

    func testLeavesNonHTTPSchemesUnchanged() {
        let url = URL(string: "data:image/gif;base64,R0lGOD")!
        let out = HTTPSRedirectingDownloaderOperation.upgradeHTTPToHTTPS(URLRequest(url: url))
        XCTAssertEqual(out.url?.absoluteString, "data:image/gif;base64,R0lGOD")
    }

    func testPreservesHeadersAndMethod() {
        var req = URLRequest(url: URL(string: "http://imgfiles.plaync.co.kr/file/x")!)
        req.httpMethod = "GET"
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        req.setValue("https://aagag.com/", forHTTPHeaderField: "Referer")
        let out = HTTPSRedirectingDownloaderOperation.upgradeHTTPToHTTPS(req)
        XCTAssertEqual(out.url?.scheme, "https")
        XCTAssertEqual(out.httpMethod, "GET")
        XCTAssertEqual(out.value(forHTTPHeaderField: "User-Agent"), "Mozilla/5.0")
        XCTAssertEqual(out.value(forHTTPHeaderField: "Referer"), "https://aagag.com/")
    }
}
