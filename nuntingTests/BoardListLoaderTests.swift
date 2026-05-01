import XCTest
@testable import nunting

/// State-machine + side-effect tests for `BoardListLoader`.
///
/// Stub fetcher returns canned HTML; the production parser still runs
/// (so we exercise the real ClienParser etc., not a parsed-result fake).
/// `BoardListCache` is fresh per test to keep cases isolated.
///
/// Captured `var` from the @Sendable fetcher closure goes through the
/// same lock-protected helpers used in `BoardCatalogStoreTests`
/// (TestCounter / TestRecorder). See those for the rationale.
final class BoardListLoaderTests: XCTestCase {

    // Smallest body that produces non-empty Posts via ClienParser.
    private let clienHTML = """
    <html><body>
    <a class="list_item symph-row" href="/service/board/news/1"
       data-board-sn="1" data-comment-count="2" data-author-id="user">
        <span data-role="list-title-text">첫번째 글</span>
        <div class="list_author"><span class="nickname">A</span></div>
        <div class="list_time"><span>2025-01-01</span></div>
    </a>
    <a class="list_item symph-row" href="/service/board/news/2"
       data-board-sn="2" data-comment-count="0" data-author-id="user2">
        <span data-role="list-title-text">두번째 글</span>
        <div class="list_author"><span class="nickname">B</span></div>
        <div class="list_time"><span>2025-01-02</span></div>
    </a>
    </body></html>
    """

    // MARK: - taskKey

    func testTaskKeyMirrorsCacheKeyExactly() {
        let loaderKey = BoardListLoader.taskKey(
            board: .clienNews, filter: nil, searchQuery: nil
        )
        let cacheKey = BoardListCache.key(
            boardID: Board.clienNews.id, filterID: nil, searchQuery: nil
        )
        XCTAssertEqual(loaderKey, cacheKey,
                       "loader 와 cache 가 같은 요청에 같은 key 를 산출해야 캐시 hit 이 일어남")
    }

    // MARK: - Cold path

    func testColdRefreshFetchesAndPopulatesPosts() async {
        let fetchCount = TestCounter()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })
        let cache = BoardListCache()

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(loader.posts.count, 2)
        XCTAssertEqual(loader.posts[0].title, "첫번째 글")
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
    }

    func testColdRefreshCachesFirstPageSnapshot() async {
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in clienHTML })
        let cache = BoardListCache()

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)

        let key = BoardListLoader.taskKey(board: .clienNews, filter: nil, searchQuery: nil)
        let cached = cache.get(taskKey: key)
        XCTAssertNotNil(cached, "성공한 cold load 후 cache 에 first-page snapshot 저장")
        XCTAssertEqual(cached?.posts.count, 2)
    }

    func testColdRefreshFailureSurfacesErrorMessage() async {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "network down" }
        }
        let loader = BoardListLoader(fetcher: { _, _, _, _ in
            throw StubError()
        })
        let cache = BoardListCache()

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)

        XCTAssertEqual(loader.errorMessage, "network down")
        XCTAssertTrue(loader.posts.isEmpty)
        XCTAssertFalse(loader.isLoading)
    }

    // MARK: - Cache hit + silent revalidate

    func testCacheHitInstantRendersThenRevalidates() async {
        let cache = BoardListCache()
        let key = BoardListLoader.taskKey(board: .clienNews, filter: nil, searchQuery: nil)
        let cachedPost = Post(
            id: "clien-news-cached",
            site: .clien,
            boardID: "clien-news",
            title: "캐시 글",
            author: "X",
            date: nil,
            dateText: "어제",
            commentCount: 0,
            url: URL(string: "https://www.clien.net/service/board/news/cached")!
        )
        cache.put(taskKey: key, posts: [cachedPost], hasMorePages: true, nextSearchURL: nil)

        let fetchCount = TestCounter()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)

        // Silent revalidate ran (cache hit triggers it) + replaced the
        // posts with fresh content from clienHTML.
        XCTAssertEqual(fetchCount.value, 1, "cache hit 시 silent revalidate 가 1회 fire")
        XCTAssertEqual(loader.posts.map(\.title), ["첫번째 글", "두번째 글"],
                       "fresh 응답으로 교체됨")
    }

    func testSilentRevalidateFailureLeavesPriorPostsVisible() async {
        struct StubError: Error {}
        let cache = BoardListCache()
        let key = BoardListLoader.taskKey(board: .clienNews, filter: nil, searchQuery: nil)
        let cachedPost = Post(
            id: "clien-news-cached",
            site: .clien,
            boardID: "clien-news",
            title: "캐시 글",
            author: "X",
            date: nil,
            dateText: "어제",
            commentCount: 0,
            url: URL(string: "https://www.clien.net/service/board/news/cached")!
        )
        cache.put(taskKey: key, posts: [cachedPost], hasMorePages: true, nextSearchURL: nil)

        let loader = BoardListLoader(fetcher: { _, _, _, _ in
            throw StubError()
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)

        XCTAssertEqual(loader.posts.map(\.title), ["캐시 글"],
                       "silent revalidate 실패 시 cache 의 이전 posts 가 그대로 보임")
        XCTAssertNil(loader.errorMessage,
                     "silent 실패는 사용자 에러로 surface 되지 않음")
    }

    // MARK: - Idempotency

    func testRefreshRefireWithSameKeyIsNoOp() async {
        let fetchCount = TestCounter()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })
        let cache = BoardListCache()

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)
        XCTAssertEqual(fetchCount.value, 1)

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)

        // Second refresh: loadedKey == key 이미 → 빠져나감. 단 cache hit
        // 이 일어나는지에 따라 silent revalidate 가 1회 더 fire 가능.
        // 실제로 첫 cold load 가 cache.put 으로 스냅샷 남겼으므로 두번째
        // refresh 는 loadedKey 매치로 즉시 return → fetch 추가 호출 0.
        XCTAssertEqual(fetchCount.value, 1,
                       "동일 key 재호출은 noop (loadedKey 가드)")
    }

    // MARK: - Reload

    func testReloadBypassesLoadedKeyShortCircuit() async {
        let fetchCount = TestCounter()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })
        let cache = BoardListCache()

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)
        XCTAssertEqual(fetchCount.value, 1)

        await loader.reload(board: .clienNews, filter: nil, searchQuery: nil, cache: cache)

        XCTAssertEqual(fetchCount.value, 2,
                       "pull-to-refresh 는 loadedKey 가드 우회 — 같은 key 라도 재페치")
    }

    // MARK: - Clien search 400 fallback

    func testClienSearch400FallbackRetriesWithCookielessRequest() async {
        // 첫 호출: 400 throw. 두번째 호출: 정상 HTML. 두 호출 다 fetcher
        // 통과해야 (test fake intercept 보장).
        let attempts = TestRecorder<(String?, Bool)>()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, ua, cookies in
            attempts.append((ua, cookies))
            if attempts.count == 1 {
                throw NetworkError.badResponse(400)
            }
            return clienHTML
        })
        let cache = BoardListCache()

        await loader.refresh(
            board: .clienNews,
            filter: nil,
            searchQuery: "맥북",
            cache: cache
        )

        XCTAssertEqual(attempts.count, 2, "primary + retry 두 번 fetcher 통과")
        let snap = attempts.snapshot
        XCTAssertNil(snap[0].0, "primary 는 ua nil")
        XCTAssertEqual(snap[0].1, true, "primary 는 cookies 사용")
        XCTAssertEqual(snap[1].0, Networking.userAgent,
                       "retry 는 explicit Networking.userAgent")
        XCTAssertEqual(snap[1].1, false,
                       "retry 는 cookies 비활성 (clien 검색 400 회복 path)")
        XCTAssertFalse(loader.posts.isEmpty, "retry 성공 시 posts 채워짐")
    }

    func testNonClien400DoesNotRetry() async {
        let attempts = TestCounter()
        let loader = BoardListLoader(fetcher: { _, _, _, _ in
            attempts.increment()
            throw NetworkError.badResponse(400)
        })
        let cache = BoardListCache()

        await loader.refresh(
            board: .invenMaple,
            filter: nil,
            searchQuery: "test",
            cache: cache
        )

        XCTAssertEqual(attempts.value, 1,
                       "clien 이 아닌 사이트는 400 retry 안 함 (일반 에러로 처리)")
        XCTAssertNotNil(loader.errorMessage)
    }

    func testClien400WithoutSearchDoesNotRetry() async {
        let attempts = TestCounter()
        let loader = BoardListLoader(fetcher: { _, _, _, _ in
            attempts.increment()
            throw NetworkError.badResponse(400)
        })
        let cache = BoardListCache()

        await loader.refresh(
            board: .clienNews,
            filter: nil,
            searchQuery: nil,  // 검색 아닌 일반 list
            cache: cache
        )

        XCTAssertEqual(attempts.value, 1,
                       "clien 이라도 검색 아닌 일반 list 의 400 은 retry 안 함")
    }
}

// MARK: - Test helpers (shared shapes)

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

private final class TestRecorder<T>: @unchecked Sendable {
    private var items: [T] = []
    private let lock = NSLock()

    func append(_ item: T) {
        lock.lock()
        defer { lock.unlock() }
        items.append(item)
    }

    var snapshot: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}
