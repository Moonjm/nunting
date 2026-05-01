import XCTest
@testable import nunting

/// State-machine + side-effect tests for `BoardListLoader`.
///
/// Stub fetcher returns canned HTML; the production parser still runs
/// (so we exercise the real ClienParser etc., not a parsed-result fake).
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

    func testTaskKeyShape() {
        let key = BoardListLoader.taskKey(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(key, "clien-news|_all|")
    }

    func testTaskKeyEncodesFilterAndSearch() {
        let chu = Board.invenMaple.filters.first { $0.id == "chu" }!
        let key = BoardListLoader.taskKey(
            board: .invenMaple,
            filter: chu,
            searchQuery: "맥북"
        )
        XCTAssertEqual(key, "inven-maple|chu|맥북")
    }

    // MARK: - Cold path

    func testRefreshFetchesAndPopulatesPosts() async {
        let fetchCount = TestCounter()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(loader.posts.count, 2)
        XCTAssertEqual(loader.posts[0].title, "첫번째 글")
        XCTAssertFalse(loader.isLoading)
        XCTAssertNil(loader.errorMessage)
    }

    func testRefreshFailureSurfacesErrorMessage() async {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "network down" }
        }
        let loader = BoardListLoader(fetcher: { _, _, _, _ in
            throw StubError()
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(loader.errorMessage, "network down")
        XCTAssertTrue(loader.posts.isEmpty)
        XCTAssertFalse(loader.isLoading)
    }

    // MARK: - Idempotency

    func testRefreshRefireWithSameKeyIsNoOp() async {
        let fetchCount = TestCounter()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(fetchCount.value, 1)

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)

        XCTAssertEqual(fetchCount.value, 1,
                       "동일 key 재호출은 noop (loadedKey 가드)")
    }

    func testRefreshOnDifferentKeyTriggersFreshFetch() async {
        // 보드 전환 path: 다른 key 로 refresh → 새로 fetch.
        // 드로어 탭과 swipe-step 양쪽 시나리오 모두 이 path 통과.
        let fetchCount = TestCounter()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(fetchCount.value, 1)

        await loader.refresh(board: .clienJirum, filter: nil, searchQuery: nil)

        XCTAssertEqual(fetchCount.value, 2,
                       "다른 보드로 refresh 시 cold path 로 새 fetch")
    }

    // MARK: - Reload (pull-to-refresh)

    func testReloadBypassesLoadedKeyShortCircuit() async {
        let fetchCount = TestCounter()
        let loader = BoardListLoader(fetcher: { [clienHTML] _, _, _, _ in
            fetchCount.increment()
            return clienHTML
        })

        await loader.refresh(board: .clienNews, filter: nil, searchQuery: nil)
        XCTAssertEqual(fetchCount.value, 1)

        await loader.reload(board: .clienNews, filter: nil, searchQuery: nil)

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

        await loader.refresh(
            board: .clienNews,
            filter: nil,
            searchQuery: "맥북"
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

        await loader.refresh(
            board: .invenMaple,
            filter: nil,
            searchQuery: "test"
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

        await loader.refresh(
            board: .clienNews,
            filter: nil,
            searchQuery: nil  // 검색 아닌 일반 list
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
