import XCTest
@testable import nunting

/// `BoardCatalogStore` revalidation tests.
///
/// We don't fake the catalog parser — the production
/// `SiteCatalogFactory.catalog(for: .clien)` (or coolenjoy / ppomppu)
/// is what gets called inside `loadIfNeeded`. Instead we inject a
/// fetcher closure that returns canned HTML for the known catalog URLs,
/// and a `now: () -> Date` clock so we can move time without sleeping.
///
/// The HTML payloads are intentionally minimal: just enough for the
/// real catalog parser to surface a non-empty group, so we can assert
/// "fetched succeeded" vs "fetched again" by counting fetcher
/// invocations and watching `lastFetchedAt`.
final class BoardCatalogStoreTests: XCTestCase {

    // Smallest body that still produces at least one Board through
    // ClienCatalog's `a.menu-list[href^=/service/board/]` selector.
    private let clienHTML = """
    <html><body>
    <a class="menu-list" href="/service/board/news"><span class="menu_over">새소식</span></a>
    </body></html>
    """

    // MARK: - Cold load

    func testColdLoadFetchesAndStampsLastFetchedAt() async {
        var fetchCount = 0
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount += 1
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount, 1, "cold load triggers fetch")
        XCTAssertNotNil(store.lastFetchedAt[.clien], "성공 시 timestamp 기록")
        XCTAssertFalse(store.boards(for: .clien).isEmpty, "그룹이 채워짐")
        XCTAssertNil(store.error(for: .clien))
    }

    func testColdLoadFailureSurfacesErrorAndDoesNotStampTimestamp() async {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "stub network failure" }
        }
        var fetchCount = 0
        let store = BoardCatalogStore(
            fetcher: { _, _, _ in
                fetchCount += 1
                throw StubError()
            },
            staleTTL: 60
        )

        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(store.error(for: .clien), "stub network failure")
        XCTAssertNil(store.lastFetchedAt[.clien], "실패 시 timestamp 미기록 — 다음 시도가 cold path 로 가야 함")
    }

    // MARK: - Skip when fresh

    func testSecondLoadWithinTTLIsNoOp() async {
        var fetchCount = 0
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount += 1
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)
        XCTAssertEqual(fetchCount, 1)

        // 30 seconds later — still within 60s TTL.
        nowProvider.advance(by: 30)
        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount, 1, "TTL 안에서는 재페치 없음")
    }

    // MARK: - Stale revalidate

    func testLoadIfNeededPastTTLSilentlyRevalidates() async {
        var fetchCount = 0
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount += 1
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)
        XCTAssertEqual(fetchCount, 1)
        let firstStamp = store.lastFetchedAt[.clien]

        // Move clock past TTL.
        nowProvider.advance(by: 90)
        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount, 2, "TTL 지나면 재페치")
        XCTAssertNotEqual(store.lastFetchedAt[.clien], firstStamp, "timestamp 갱신")
        XCTAssertFalse(store.isLoading(.clien), "silent revalidate 는 spinner 안 띄움")
    }

    func testStaleRevalidateFailureLeavesPriorCatalogVisible() async {
        struct StubError: Error {}
        var fetchCount = 0
        var shouldFail = false
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount += 1
                if shouldFail { throw StubError() }
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)
        let priorBoards = store.boards(for: .clien)
        XCTAssertFalse(priorBoards.isEmpty)

        // Past TTL — next call attempts silent revalidate, which fails.
        nowProvider.advance(by: 90)
        shouldFail = true
        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(store.boards(for: .clien).map(\.id), priorBoards.map(\.id),
                       "silent revalidate 실패는 기존 카탈로그를 그대로 보존")
        XCTAssertNil(store.error(for: .clien),
                     "silent revalidate 실패는 사용자에 에러로 surface 되지 않음")
    }

    // MARK: - revalidateLoadedCatalogs

    func testRevalidateLoadedCatalogsOnlyTouchesStaleSites() async {
        var fetchCount = 0
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount += 1
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)  // fetch #1
        XCTAssertEqual(fetchCount, 1)

        // Within TTL — revalidate should noop.
        nowProvider.advance(by: 10)
        await store.revalidateLoadedCatalogs()
        XCTAssertEqual(fetchCount, 1, "fresh 사이트는 revalidate 가 건너뜀")

        // Past TTL — revalidate hits.
        nowProvider.advance(by: 100)
        await store.revalidateLoadedCatalogs()
        XCTAssertEqual(fetchCount, 2, "stale 사이트만 silent re-fetch")
    }

    func testRevalidateLoadedCatalogsSkipsNeverLoadedSites() async {
        var fetchCount = 0
        let store = BoardCatalogStore(
            fetcher: { _, _, _ in
                fetchCount += 1
                return ""
            },
            staleTTL: 0  // 즉시 stale 이지만 groups 가 비어있어야 함
        )

        // Never called loadIfNeeded — nothing in `groups`.
        await store.revalidateLoadedCatalogs()

        XCTAssertEqual(fetchCount, 0, "사용자가 한 번도 안 연 사이트는 revalidate 도 안 함")
    }

    // MARK: - PpomppuCatalog routes through injected fetcher

    func testPpomppuCatalogUsesInjectedFetcherWithDesktopUserAgent() async {
        // Regression net for the silent-bypass PpomppuCatalog used to
        // have (calling `Networking.fetchHTML` directly because it
        // needed a desktop UA). After the seam widened to
        // (URL, encoding, ua?), ppomppu must route every fetch through
        // the injected closure or the test seam silently rots.
        var seenUserAgents: [String?] = []
        let stubBody = """
        <html><body>
        <li class="menu01"><a href="/zboard.php?id=ppomppu">뽐뿌게시판</a></li>
        </body></html>
        """
        let store = BoardCatalogStore(
            fetcher: { _, _, ua in
                seenUserAgents.append(ua)
                return stubBody
            }
        )
        await store.loadIfNeeded(.ppomppu)

        XCTAssertFalse(seenUserAgents.isEmpty,
                       "PpomppuCatalog 가 injected fetcher 로 통과 안 함 — 이전의 silent bypass 회귀")
        XCTAssertTrue(
            seenUserAgents.allSatisfy { $0 != nil && $0!.contains("Macintosh") },
            "ppomppu 의 모든 fetch 호출이 desktop UA 를 fetcher 의 3번째 인자로 전달해야 함"
        )
    }
}

/// Test-only mutable clock so cases can advance time without `Date.now`
/// drift or `Task.sleep`. Captured by reference via the `read` closure
/// passed into `BoardCatalogStore.now`.
private final class MutableClock: @unchecked Sendable {
    private var current: Date
    private let lock = NSLock()

    init(initial: Date) {
        self.current = initial
    }

    var read: @Sendable () -> Date {
        { [weak self] in
            guard let self else { return Date() }
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.current
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
