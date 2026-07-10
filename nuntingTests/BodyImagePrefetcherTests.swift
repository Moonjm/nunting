import SDWebImage
import XCTest
@testable import nunting

@MainActor
final class BodyImagePrefetcherTests: XCTestCase {

    private func url(_ i: Int) -> URL { URL(string: "https://cdn.example.com/\(i).webp")! }
    private func urls(_ n: Int) -> [URL] { (0..<n).map(url) }

    func testPrefetchContextMatchesNetworkImageThumbnailKey() {
        // 워밍과 표시 로드의 SD 캐시 키 일치 계약 — thumbnail 컨텍스트는
        // 캐시 키를 `URL-Thumbnail({w,h},1)` 로 변형하므로, 프리페처가
        // 컨텍스트 없이 워밍하면 표시 로드가 그 결과를 못 찾아 프리페치가
        // 통째로 무효가 된다 (실측: aagag 첫 진입 "다시 시도" 버그의 창을
        // 연 회귀). atsSafe URL 일치와 같은 결의 불변식.
        let ctx = NetworkImage.thumbnailContext(maxPointSize: nil, maxPointWidth: 393, scale: 3)
        let p = BodyImagePrefetcher(urls: urls(3), window: 3, thumbnailContext: ctx)
        let stored = (p.prefetchContext?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(stored, CGSize(width: 1179, height: NetworkImage.tallImageMaxPixelHeight))

        let bare = BodyImagePrefetcher(urls: urls(3), window: 3)
        XCTAssertNil(bare.prefetchContext, "컨텍스트 없는 호출부(구형)는 평범한 키 워밍 유지")
    }

    /// 파서 aspect 를 아는 극단 세로형은 표시 로드가 처음부터 tall 박스를
    /// 쓰므로, 프리페치도 같은 tall 컨텍스트로 워밍해야 캐시 키가 일치한다
    /// (Codex P2 — 표준 박스로 워밍하면 look-ahead 가 통째로 무효).
    /// 맵에 없는 URL 은 종전 공유 컨텍스트 유지.
    func testPerURLContextForKnownTallImages() {
        let std = NetworkImage.thumbnailContext(maxPointSize: nil, maxPointWidth: 393, scale: 3)
        let tall = NetworkImage.thumbnailContext(
            maxPointSize: nil, maxPointWidth: 393, aspect: 1.0 / 30.0, scale: 3)
        let p = BodyImagePrefetcher(
            urls: urls(3), window: 3,
            thumbnailContext: std,
            contextByURL: [url(1): tall!])

        let tallBox = (p.prefetchContext(for: url(1))?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(tallBox?.height, NetworkImage.tallImageHardMaxPixelHeight,
                       "맵에 있는 URL 은 tall 박스로 워밍")
        let stdBox = (p.prefetchContext(for: url(0))?[.imageThumbnailPixelSize] as? NSValue)?.cgSizeValue
        XCTAssertEqual(stdBox, CGSize(width: 1179, height: NetworkImage.tallImageMaxPixelHeight),
                       "맵에 없는 URL 은 공유 컨텍스트")
    }

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

    func testVisibleIndexItselfIsMarkedAsRequested() {
        // url(0) repeats at index 3. With window 1 the prefetcher never warms
        // index 3 ahead of anyone, but url(0) must already be in `requested`
        // from when index 0 was visible (it's loaded on-screen), so visiting
        // index 2 — whose window is index 3 = url(0) — yields nothing.
        let p = BodyImagePrefetcher(urls: [url(0), url(1), url(2), url(0)], window: 1)
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 0), [url(1)])
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 1), [url(2)])
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 2), [])
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

    func testSkipPrefetchURLsAreOmittedFromFetchButStillMarkedRequested() {
        // url(2) is a heavy webp (first-frame-only inline) → must not be
        // prefetched (its full decode blocks the serial queue). It still
        // occupies its slot: window from index 0 is {1,2,3}, 2 dropped.
        let p = BodyImagePrefetcher(urls: urls(10), window: 3, skipPrefetch: [url(2)])
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 0), [url(1), url(3)],
                       "skip-listed url(2) omitted from the prefetch list")
        // url(2) was marked requested, so re-windowing over it adds nothing;
        // index 1's window {2,3,4} yields only the still-fresh url(4).
        XCTAssertEqual(p.claimFreshURLs(forVisibleIndex: 1), [url(4)])
    }
}
