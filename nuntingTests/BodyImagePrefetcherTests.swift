import XCTest
@testable import nunting

@MainActor
final class BodyImagePrefetcherTests: XCTestCase {

    private func url(_ i: Int) -> URL { URL(string: "https://cdn.example.com/\(i).webp")! }
    private func urls(_ n: Int) -> [URL] { (0..<n).map(url) }

    func testClaimsWindowAheadOfVisibleIndex() {
        let p = BodyImagePrefetcher(urls: urls(10), window: 3)
        // Visible index 0 → warm 1, 2, 3.
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 0), [url(1), url(2), url(3)])
    }

    func testDoesNotReissueAlreadyClaimedURLs() {
        let p = BodyImagePrefetcher(urls: urls(10), window: 3)
        _ = p.claimFreshURLs(forVisibleIndex: 0)            // claims 1,2,3
        // Visible index 1's window (2,3,4) overlaps — only 4 is fresh.
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 1), [url(4)])
        // Re-firing the same index now yields nothing.
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 0), [])
    }

    func testClampsWindowAtEndOfList() {
        let p = BodyImagePrefetcher(urls: urls(5), window: 3)
        // Index 3 → only index 4 remains ahead.
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 3), [url(4)])
        // Last image → nothing ahead.
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 4), [])
    }

    func testOutOfRangeIndexIsNoOp() {
        let p = BodyImagePrefetcher(urls: urls(5), window: 3)
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 99), [])
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: -5), [])
    }

    func testEmptyURLListIsNoOp() {
        let p = BodyImagePrefetcher(urls: [], window: 3)
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 0), [])
    }

    func testPromotesHTTPToHTTPSForCacheKeyParity() {
        // The on-screen `NetworkImage` loads `url.atsSafe`, so the prefetch
        // must warm the https key, not the raw http one.
        let httpURLs = [
            URL(string: "https://cdn.example.com/0.webp")!,
            URL(string: "http://cdn.example.com/1.webp")!,
        ]
        let p = BodyImagePrefetcher(urls: httpURLs, window: 3)
        XCTAssertEqual(
            p.claimFreshURLs(forVisibleIndex: 0),
            [URL(string: "https://cdn.example.com/1.webp")!]
        )
    }

    func testDedupCollapsesSchemeNormalizedDuplicates() {
        // Same image listed as both http and https collapses to one key
        // after `atsSafe` — the `requested` set is post-normalization, so the
        // second occurrence must not be re-queued.
        let dupes = [
            URL(string: "https://cdn.example.com/0.webp")!,
            URL(string: "http://cdn.example.com/1.webp")!,
            URL(string: "https://cdn.example.com/1.webp")!,
        ]
        let p = BodyImagePrefetcher(urls: dupes, window: 3)
        XCTAssertEqual(
            p.claimFreshURLs(forVisibleIndex: 0),
            [URL(string: "https://cdn.example.com/1.webp")!]
        )
    }
}
