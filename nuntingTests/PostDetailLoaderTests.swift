import XCTest
@testable import nunting

/// State-machine + side-effect tests for `PostDetailLoader`.
///
/// Mirrors `BoardListLoaderTests`: stub fetcher / resolver via the
/// loader's seam typealiases, then drive `load(post:cache:renderReadyAt:)`
/// directly. The production parsers run unmodified so we exercise the
/// real BobaeParser / AagagParser dispatch instead of a parsed-result
/// fake.
///
/// Bobaedream's "삭제된 글" sentinel HTML (`<script>alert('삭제된 글 ...
/// ');history.back();</script>`) is BobaeParser's pre-DOM short-circuit
/// — it produces a deterministic `PostDetail` with a single placeholder
/// text block without needing a full DOM fixture, which keeps the cold-
/// load tests focused on loader plumbing rather than parser markup.
///
/// `renderReadyAt: .now` skips the navigation-push render gate (the gate
/// only sleeps when the deadline is in the future), so tests don't pay
/// the 400 ms wall-clock the production view does.
@MainActor
final class PostDetailLoaderTests: XCTestCase {

    // BobaeParser's pre-DOM sentinel: returns a placeholder PostDetail
    // with `.text("삭제되거나 이동된 게시물입니다.")` blocks, no fetch
    // through SwiftSoup. Reused across happy-path / dispatch tests.
    private let bobaeDeletedHTML = """
    <html><body>
    <script>alert('삭제된 글 입니다.'); history.back();</script>
    </body></html>
    """

    private func bobaePost(id: String = "bobae-1") -> Post {
        Post(
            id: id,
            site: .bobae,
            boardID: "freeb",
            title: "테스트",
            author: "작성자",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/freeb/\(id)")!
        )
    }

    private func aagagMirrorPost(id: String = "aagag-1") -> Post {
        Post(
            id: id,
            site: .aagag,
            boardID: "mirror",
            title: "미러",
            author: "aagag",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            url: URL(string: "https://aagag.com/mirror/re?ss=\(id)")!
        )
    }

    private func now() -> ContinuousClock.Instant { ContinuousClock.now }

    // MARK: - Cache short-circuit

    func testCacheHitRestoresInstantlyAndSkipsFetch() async {
        let fetchCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                fetchCount.increment()
                return ""
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = bobaePost()
        let cached = PostDetail(
            post: post,
            blocks: [.text("warm")],
            fullDateText: "캐시",
            viewCount: 99,
            source: nil,
            comments: []
        )
        cache.put(id: post.id, detail: cached)

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(fetchCount.value, 0,
                       "캐시 히트 시 fetcher 호출 안 함")
        XCTAssertEqual(loader.detail?.fullDateText, "캐시")
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
    }

    // MARK: - Cold path

    func testColdLoadPopulatesDetailAndCaches() async {
        let fetchCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { [bobaeDeletedHTML] _, _ in
                fetchCount.increment()
                return bobaeDeletedHTML
            },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = bobaePost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertNotNil(loader.detail)
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
        XCTAssertNotNil(cache.get(id: post.id),
                        "성공 시 cache.put 으로 결과 저장")
    }

    func testFetcherErrorSurfacesErrorMessageAndSkipsCache() async {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "fetch failed" }
        }
        let loader = PostDetailLoader(
            fetcher: { _, _ in throw StubError() },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = bobaePost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(loader.errorMessage, "fetch failed")
        XCTAssertNil(loader.detail)
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(cache.get(id: post.id),
                     "에러 시 cache 미오염")
    }

    // MARK: - Aagag dispatch

    func testAagagMirrorToUnknownHostYieldsExternalPlaceholder() async {
        // Resolver redirects to a site we don't recognise → loader builds
        // a "외부 사이트로 이동" placeholder, no fetcher / parser call.
        let fetchCount = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                fetchCount.increment()
                return ""
            },
            resolver: { _ in
                Networking.ResolvedRedirect(url: URL(string: "https://example.com/article/42")!,
                      prefetchedBody: nil)
            }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = aagagMirrorPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(fetchCount.value, 0,
                       "외부 host 로 dispatch → fetcher 통과 안 함")
        guard let detail = loader.detail else {
            XCTFail("external placeholder detail 누락"); return
        }
        XCTAssertEqual(detail.blocks.count, 1)
        if case .dealLink(let url, let label) = detail.blocks[0].kind {
            XCTAssertEqual(url.host, "example.com")
            XCTAssertTrue(label.hasPrefix("외부 사이트로 이동"))
        } else {
            XCTFail("blocks[0] 가 dealLink 아님: \(detail.blocks[0].kind)")
        }
        XCTAssertNotNil(cache.get(id: post.id),
                        "external placeholder 도 캐시 저장")
    }

    func testAagagMirrorToKnownSourceDispatchesToSourceParser() async {
        // Resolver redirects aagag mirror → bobaedream → BobaeParser
        // sentinel placeholder. Fetcher should NOT be called because the
        // resolved redirect carries `prefetchedBody`.
        let fetchCount = TestCounter()
        let prefetched = bobaeDeletedHTML.data(using: .utf8)!
        let loader = PostDetailLoader(
            fetcher: { _, _ in
                fetchCount.increment()
                return ""
            },
            resolver: { _ in
                Networking.ResolvedRedirect(url: URL(string: "https://m.bobaedream.co.kr/board/bbs_view/freeb/42")!,
                      prefetchedBody: prefetched)
            }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = aagagMirrorPost()

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(fetchCount.value, 0,
                       "prefetched body 가 있으면 fetcher 재호출 안 함")
        XCTAssertNotNil(loader.detail)
        XCTAssertFalse(loader.isLoading)
    }

    func testAagagMirrorWithoutSsQueryFallsThroughToAagagParser() async {
        // post.url 이 /mirror/re 패턴이지만 ss 쿼리 없음 → resolver 우회,
        // 원본 post (aagag) 로 parser 디스패치. AagagParser 가 입력을
        // 받아 throw 하면 errorMessage, 아니면 detail. 여기선 빈 HTML →
        // 일반적으로 AagagParser 가 structureChanged 류를 throw 하므로
        // errorMessage 가 채워지면 충분.
        let resolverCalled = TestCounter()
        let loader = PostDetailLoader(
            fetcher: { _, _ in "<html></html>" },
            resolver: { url in
                resolverCalled.increment()
                return Networking.ResolvedRedirect(url: url, prefetchedBody: nil)
            }
        )
        let cache = PostDetailCache(capacity: 4)
        let post = Post(
            id: "x",
            site: .aagag,
            boardID: "issue",
            title: "이슈",
            author: "aagag",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            // /mirror/re 아닌 경로 → 미러 분기 우회
            url: URL(string: "https://aagag.com/issue/?idx=42")!
        )

        await loader.load(post: post, cache: cache, renderReadyAt: now())

        XCTAssertEqual(resolverCalled.value, 0,
                       "/mirror/re ss=… 매칭 실패 시 resolver 호출 안 함")
        // AagagParser 가 빈 HTML 을 거부하면 errorMessage, 통과하면 detail.
        // 두 경로 모두 isLoading=false 로 정착하면 OK.
        XCTAssertFalse(loader.isLoading)
    }

    // MARK: - Initial state

    func testInitialIsLoadingTrueBeforeFirstLoadCall() {
        let loader = PostDetailLoader(
            fetcher: { _, _ in "" },
            resolver: { url in Networking.ResolvedRedirect(url: url, prefetchedBody: nil) }
        )
        XCTAssertTrue(loader.isLoading,
                      "init 직후 isLoading=true 로 시작 (첫 frame 에서 spinner)")
        XCTAssertNil(loader.detail)
        XCTAssertNil(loader.errorMessage)
    }
}

// MARK: - Test helpers

private final class TestCounter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        n += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return n
    }
}
