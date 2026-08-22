import XCTest
import ObjectiveC.runtime
@testable import nunting

final class HTTPSRedirectingDownloaderOperationTests: XCTestCase {
    /// Runtime regression net: SDWebImageDownloader dispatches the redirect
    /// callback via the literal ObjC selector
    /// `URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:`
    /// (uppercase URL). Swift's auto-bridging on overrides of optional
    /// protocol methods can silently lowercase the selector when the parent
    /// class's actual impl lives in a .m file — and the runtime then fires
    /// "unrecognized selector sent to instance" on first redirect. This test
    /// confirms our subclass installs the method under the exact uppercase
    /// selector by inspecting the class's own method list.
    func testRegistersRedirectSelectorOnOwnClass() {
        let cls: AnyClass = HTTPSRedirectingDownloaderOperation.self
        var count: UInt32 = 0
        guard let methodList = class_copyMethodList(cls, &count) else {
            XCTFail("class_copyMethodList returned nil — no methods on subclass")
            return
        }
        defer { free(methodList) }

        let target = "URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:"
        var registeredSelectors: [String] = []
        var found = false
        for i in 0..<Int(count) {
            let name = NSStringFromSelector(method_getName(methodList[i]))
            registeredSelectors.append(name)
            if name == target { found = true }
        }
        XCTAssertTrue(
            found,
            "Subclass must register `\(target)` under exact uppercase selector. " +
                "Currently registered: \(registeredSelectors)"
        )
    }

    /// 같은 종류의 런타임 함정 — `SDWebImageDownloader` 는 수집된 태스크 메트릭도
    /// 대문자 셀렉터 `URLSession:task:didFinishCollectingMetrics:` 로만 넘긴다
    /// (`SDWebImageDownloader.m:541`). Swift 자동 브리징이 소문자로 등록하면
    /// `respondsToSelector` 가 false 가 돼 이미지 네트워크 계측이 **조용히** 0건이 된다.
    func testRegistersMetricsSelectorOnOwnClass() {
        let cls: AnyClass = HTTPSRedirectingDownloaderOperation.self
        var count: UInt32 = 0
        guard let methodList = class_copyMethodList(cls, &count) else {
            XCTFail("class_copyMethodList returned nil — no methods on subclass")
            return
        }
        defer { free(methodList) }

        let target = "URLSession:task:didFinishCollectingMetrics:"
        var registeredSelectors: [String] = []
        for i in 0..<Int(count) {
            registeredSelectors.append(NSStringFromSelector(method_getName(methodList[i])))
        }
        XCTAssertTrue(
            registeredSelectors.contains(target),
            "Subclass must register `\(target)` under exact uppercase selector. " +
                "Currently registered: \(registeredSelectors)"
        )
    }

    /// 전송 완료 콜백도 같은 대문자 셀렉터로만 전달된다
    /// (`SDWebImageDownloader.m:506`). 소문자로 등록되면 계측이 조용히 0건이 되고,
    /// 더 나쁘게는 부모 구현이 안 불려 오퍼레이션이 안 끝난다.
    func testRegistersDidCompleteSelectorOnOwnClass() {
        let cls: AnyClass = HTTPSRedirectingDownloaderOperation.self
        var count: UInt32 = 0
        guard let methodList = class_copyMethodList(cls, &count) else {
            XCTFail("class_copyMethodList returned nil")
            return
        }
        defer { free(methodList) }

        let target = "URLSession:task:didCompleteWithError:"
        let registered = (0..<Int(count)).map {
            NSStringFromSelector(method_getName(methodList[$0]))
        }
        XCTAssertTrue(registered.contains(target),
                      "`\(target)` 미등록. 현재: \(registered)")
    }

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

    func testUpgradePreservesPortAndFragment() {
        let url = URL(string: "http://host.example.com:8080/path?q=1#frag")!
        let out = HTTPSRedirectingDownloaderOperation.upgradeHTTPToHTTPS(URLRequest(url: url))
        XCTAssertEqual(
            out.url?.absoluteString,
            "https://host.example.com:8080/path?q=1#frag",
            "port + query + fragment must survive scheme swap"
        )
    }

    func testUpgradeHandlesMixedCaseScheme() {
        let url = URL(string: "HTTP://host.example.com/x")!
        let out = HTTPSRedirectingDownloaderOperation.upgradeHTTPToHTTPS(URLRequest(url: url))
        XCTAssertEqual(
            out.url?.scheme?.lowercased(),
            "https",
            "scheme comparison is case-insensitive — mixed-case http should still upgrade"
        )
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
