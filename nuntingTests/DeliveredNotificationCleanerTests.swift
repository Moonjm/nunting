import XCTest
@testable import nunting

final class DeliveredNotificationCleanerTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - PostNotificationKey

    func testKeyFromPpomppuMobileURL() {
        let key = PostNotificationKey.make(
            from: url("https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=12345"))
        XCTAssertEqual(key, "ppomppu-12345")
    }

    func testKeyFoldsHostVariants() {
        // The alert server emits an `m.` URL; a feed-opened post may carry
        // a `www.` one. Both must resolve to the same key.
        let mobile = PostNotificationKey.make(
            from: url("https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=999"))
        let desktop = PostNotificationKey.make(
            from: url("https://www.ppomppu.co.kr/zboard/view.php?id=ppomppu&no=999"))
        XCTAssertEqual(mobile, "ppomppu-999")
        XCTAssertEqual(mobile, desktop)
    }

    func testKeyIgnoresExtraQueryAndOrder() {
        let a = PostNotificationKey.make(
            from: url("https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=42&page=3"))
        let b = PostNotificationKey.make(
            from: url("https://m.ppomppu.co.kr/new/bbs_view.php?no=42&id=ppomppu"))
        XCTAssertEqual(a, "ppomppu-42")
        XCTAssertEqual(a, b)
    }

    func testKeyFallsBackToSiteWhenBoardMissing() {
        let key = PostNotificationKey.make(
            from: url("https://m.ppomppu.co.kr/new/bbs_view.php?no=7"))
        XCTAssertEqual(key, "ppomppu-7", "no board id → site.rawValue prefix")
    }

    func testKeyNilWhenNoPostNumber() {
        XCTAssertNil(PostNotificationKey.make(
            from: url("https://m.ppomppu.co.kr/new/bbs_list.php?id=ppomppu")))
    }

    func testKeyNilForUnknownHost() {
        XCTAssertNil(PostNotificationKey.make(
            from: url("https://example.com/post?id=ppomppu&no=12345")))
    }

    // MARK: - DeliveredAlertMatcher

    func testMatchesSamePostAcrossHostVariants() {
        let delivered = [
            DeliveredAlert(identifier: "n1",
                           urlString: "https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=555",
                           alertID: 10)
        ]
        let matches = DeliveredAlertMatcher.matches(
            viewedPostURL: url("https://www.ppomppu.co.kr/zboard/view.php?id=ppomppu&no=555&page=2"),
            in: delivered)
        XCTAssertEqual(matches.map(\.identifier), ["n1"])
    }

    func testDifferentPostNumberDoesNotMatch() {
        let delivered = [
            DeliveredAlert(identifier: "n1",
                           urlString: "https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=100",
                           alertID: 1)
        ]
        let matches = DeliveredAlertMatcher.matches(
            viewedPostURL: url("https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=200"),
            in: delivered)
        XCTAssertTrue(matches.isEmpty)
    }

    func testOnlyMatchingEntriesReturnedFromMixedList() {
        let delivered = [
            DeliveredAlert(identifier: "match",
                           urlString: "https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=1",
                           alertID: 11),
            DeliveredAlert(identifier: "other-post",
                           urlString: "https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=2",
                           alertID: 12),
            DeliveredAlert(identifier: "no-url", urlString: nil, alertID: 13),
            DeliveredAlert(identifier: "garbage-url", urlString: "not a url", alertID: 14),
        ]
        let matches = DeliveredAlertMatcher.matches(
            viewedPostURL: url("https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=1"),
            in: delivered)
        XCTAssertEqual(matches.map(\.identifier), ["match"])
        XCTAssertEqual(matches.first?.alertID, 11)
    }

    func testNoMatchesWhenViewedURLNotAPost() {
        let delivered = [
            DeliveredAlert(identifier: "n1",
                           urlString: "https://m.ppomppu.co.kr/new/bbs_view.php?id=ppomppu&no=1",
                           alertID: 1)
        ]
        let matches = DeliveredAlertMatcher.matches(
            viewedPostURL: url("https://example.com/whatever"),
            in: delivered)
        XCTAssertTrue(matches.isEmpty)
    }
}
