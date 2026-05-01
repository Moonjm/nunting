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
///
/// Captured state (counters, flags, recorders) goes through reference-
/// typed `@unchecked Sendable` helpers below — `BoardCatalogStore`'s
/// fetcher runs inside `Task.detached`, so a `var` capture would be a
/// data race under Swift 6 strict concurrency. `Task.detached(...).value`
/// already happens-before the test's reads in practice, but the helpers
/// make that explicit at the type level.
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
        let fetchCount = TestCounter()
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount.increment()
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount.value, 1, "cold load triggers fetch")
        XCTAssertNotNil(store.lastFetchedAt[.clien], "성공 시 timestamp 기록")
        XCTAssertFalse(store.boards(for: .clien).isEmpty, "그룹이 채워짐")
        XCTAssertNil(store.error(for: .clien))
    }

    func testColdLoadFailureSurfacesErrorAndDoesNotStampTimestamp() async {
        struct StubError: Error, LocalizedError {
            var errorDescription: String? { "stub network failure" }
        }
        let fetchCount = TestCounter()
        let store = BoardCatalogStore(
            fetcher: { _, _, _ in
                fetchCount.increment()
                throw StubError()
            },
            staleTTL: 60
        )

        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount.value, 1)
        XCTAssertEqual(store.error(for: .clien), "stub network failure")
        XCTAssertNil(store.lastFetchedAt[.clien], "실패 시 timestamp 미기록 — 다음 시도가 cold path 로 가야 함")
    }

    // MARK: - Skip when fresh

    func testSecondLoadWithinTTLIsNoOp() async {
        let fetchCount = TestCounter()
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount.increment()
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)
        XCTAssertEqual(fetchCount.value, 1)

        // 30 seconds later — still within 60s TTL.
        nowProvider.advance(by: 30)
        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount.value, 1, "TTL 안에서는 재페치 없음")
    }

    // MARK: - Stale revalidate

    func testLoadIfNeededPastTTLSilentlyRevalidates() async {
        let fetchCount = TestCounter()
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount.increment()
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)
        XCTAssertEqual(fetchCount.value, 1)
        let firstStamp = store.lastFetchedAt[.clien]

        // Move clock past TTL.
        nowProvider.advance(by: 90)
        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount.value, 2, "TTL 지나면 재페치")
        XCTAssertNotEqual(store.lastFetchedAt[.clien], firstStamp, "timestamp 갱신")
        XCTAssertFalse(store.isLoading(.clien), "silent revalidate 는 spinner 안 띄움")
    }

    func testStaleRevalidateFailureLeavesPriorCatalogVisible() async {
        struct StubError: Error {}
        let fetchCount = TestCounter()
        let shouldFail = TestFlag()
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount.increment()
                if shouldFail.isSet { throw StubError() }
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
        shouldFail.set(true)
        await store.loadIfNeeded(.clien)

        XCTAssertEqual(fetchCount.value, 2)
        XCTAssertEqual(store.boards(for: .clien).map(\.id), priorBoards.map(\.id),
                       "silent revalidate 실패는 기존 카탈로그를 그대로 보존")
        XCTAssertNil(store.error(for: .clien),
                     "silent revalidate 실패는 사용자에 에러로 surface 되지 않음")
    }

    // MARK: - revalidateLoadedCatalogs

    func testRevalidateLoadedCatalogsOnlyTouchesStaleSites() async {
        let fetchCount = TestCounter()
        let nowProvider = MutableClock(initial: Date())
        let store = BoardCatalogStore(
            fetcher: { [clienHTML] _, _, _ in
                fetchCount.increment()
                return clienHTML
            },
            staleTTL: 60,
            now: nowProvider.read
        )

        await store.loadIfNeeded(.clien)  // fetch #1
        XCTAssertEqual(fetchCount.value, 1)

        // Within TTL — revalidate should noop.
        nowProvider.advance(by: 10)
        await store.revalidateLoadedCatalogs()
        XCTAssertEqual(fetchCount.value, 1, "fresh 사이트는 revalidate 가 건너뜀")

        // Past TTL — revalidate hits.
        nowProvider.advance(by: 100)
        await store.revalidateLoadedCatalogs()
        XCTAssertEqual(fetchCount.value, 2, "stale 사이트만 silent re-fetch")
    }

    func testRevalidateLoadedCatalogsSkipsNeverLoadedSites() async {
        let fetchCount = TestCounter()
        let store = BoardCatalogStore(
            fetcher: { _, _, _ in
                fetchCount.increment()
                return ""
            },
            staleTTL: 0  // 즉시 stale 이지만 groups 가 비어있어야 함
        )

        // Never called loadIfNeeded — nothing in `groups`.
        await store.revalidateLoadedCatalogs()

        XCTAssertEqual(fetchCount.value, 0, "사용자가 한 번도 안 연 사이트는 revalidate 도 안 함")
    }

    // MARK: - PpomppuCatalog routes through injected fetcher

    func testPpomppuCatalogUsesInjectedFetcherWithDesktopUserAgent() async {
        // Regression net for the silent-bypass PpomppuCatalog used to
        // have (calling `Networking.fetchHTML` directly because it
        // needed a desktop UA). After the seam widened to
        // (URL, encoding, ua?), ppomppu must route every fetch through
        // the injected closure or the test seam silently rots.
        let seenUserAgents = TestRecorder<String?>()
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

        // 두 번 (home + forum URL). 누가 둘 중 한 fetch 만 다시
        // 우회시켜도 (partial bypass) 즉시 깨지도록 정확한 카운트.
        XCTAssertEqual(
            seenUserAgents.count, 2,
            "ppomppu 는 home + forum 두 fetch 모두 seam 통과해야 함"
        )
        // Macintosh 부분 매치 대신 정확한 동등성 — 누가 향후
        // userAgent: nil 로 되돌리면 (= 세션 기본 모바일 UA) 즉시
        // fail. desktopUserAgent 자체가 바뀌면 이 테스트가 동시에
        // 갱신돼야 한다는 신호.
        XCTAssertTrue(
            seenUserAgents.snapshot.allSatisfy { $0 == Networking.desktopUserAgent },
            "ppomppu 의 모든 fetch 호출이 정확히 Networking.desktopUserAgent 로 라우팅돼야 함"
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

/// Thread-safe counter for fetcher-call accounting in tests.
/// `BoardCatalogStore` runs the injected fetcher inside `Task.detached`;
/// a `var` capture from the test method would be a data race under
/// Swift 6 strict concurrency even though `Task.detached(...).value`
/// already happens-before the test's reads. Wrapping the counter in
/// a reference type with explicit locking makes that intent type-safe.
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

/// Same shape as `TestCounter` but for boolean flags toggled across
/// the actor boundary (test-side `set(true)` before an `await`, then
/// read inside the detached fetcher).
private final class TestFlag: @unchecked Sendable {
    private var on = false
    private let lock = NSLock()

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        on = value
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }
}

/// Thread-safe append-only collector. Used by the ppomppu seam test
/// to record the User-Agent argument seen on each fetcher call.
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
