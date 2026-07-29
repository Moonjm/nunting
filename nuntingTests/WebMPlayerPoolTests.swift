import XCTest
@testable import nunting

@MainActor
final class WebMPlayerPoolTests: XCTestCase {

    /// Stub leaseholder — records `tryRecreateWebView()` calls so tests
    /// can verify promotion fires on the right view in the right order.
    private final class StubHolder: WebMPlayerPool.Leaseholder {
        let name: String
        private(set) var recreateCalls = 0
        private(set) var evictCalls = 0
        init(_ name: String) { self.name = name }
        func tryRecreateWebView() { recreateCalls += 1 }
        func releaseWebViewForPoolEviction() { evictCalls += 1 }
    }

    private var pool: WebMPlayerPool!

    override func setUp() async throws {
        try await super.setUp()
        pool = WebMPlayerPool.shared
        pool.resetForTesting()
    }

    override func tearDown() async throws {
        pool.resetForTesting()
        try await super.tearDown()
    }

    func testAcquireGrantsUpToCap() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        XCTAssertTrue(pool.acquire(a))
        XCTAssertTrue(pool.acquire(b))
        XCTAssertEqual(pool.leaseCount, 2)
        XCTAssertEqual(pool.waiterCount, 0)
    }

    func testAcquireBeyondCapQueuesWaiter() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        XCTAssertTrue(pool.acquire(a))
        XCTAssertTrue(pool.acquire(b))
        XCTAssertFalse(pool.acquire(c), "cap=2, third is denied")
        XCTAssertEqual(pool.leaseCount, 2)
        XCTAssertEqual(pool.waiterCount, 1)
        XCTAssertEqual(c.recreateCalls, 0, "waiter not yet promoted")
    }

    func testReleasePromotesOldestWaiter() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        let d = StubHolder("d")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        _ = pool.acquire(c) // waiter
        _ = pool.acquire(d) // waiter
        pool.release(a)
        XCTAssertEqual(c.recreateCalls, 1, "oldest waiter (c) promoted on release")
        XCTAssertEqual(d.recreateCalls, 0, "d still queued")
    }

    func testRepeatedAcquireRefreshesPosition() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        // a re-acquires (e.g. SwiftUI re-mount). Should remain in pool,
        // not double-count, and not displace b.
        XCTAssertTrue(pool.acquire(a))
        XCTAssertEqual(pool.leaseCount, 2)
        XCTAssertFalse(pool.acquire(c), "still at cap after a's refresh")
    }

    func testReleaseDeniedHolderClearsWaiterEntry() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        _ = pool.acquire(c) // waiter
        pool.release(c)
        XCTAssertEqual(pool.waiterCount, 0, "release on a denied holder cleans the waiter list")
    }

    func testDuplicateAcquireOnWaiterListIsIdempotent() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        XCTAssertFalse(pool.acquire(c))
        XCTAssertFalse(pool.acquire(c), "second acquire while denied is no-op on waiters")
        XCTAssertEqual(pool.waiterCount, 1)
    }

    func testReleaseTriggersChainedPromotionWhenWaiterDealloc() {
        // c (waiter) deallocates before promotion. When a releases, the
        // pool should skip the dead waiter and try the next live one (d).
        let a = StubHolder("a")
        let b = StubHolder("b")
        var c: StubHolder? = StubHolder("c")
        let d = StubHolder("d")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        _ = pool.acquire(c!)
        _ = pool.acquire(d)
        c = nil // drop strong ref; waiter list has weak ref
        pool.release(a)
        XCTAssertEqual(d.recreateCalls, 1, "d promoted after stale c skipped")
    }

    func testReleaseOnNeverAcquiredHolderIsNoOp() {
        // release 가 dismantleUIView 외 경로 (e.g. view 가 acquire 전
        // 즉시 사라지는 race) 에서도 안전해야 함. 비어있는 풀 상태에서
        // release 가 어떤 부수효과도 없어야 함.
        let stranger = StubHolder("stranger")
        pool.release(stranger) // must not crash, must not promote anything
        XCTAssertEqual(pool.leaseCount, 0)
        XCTAssertEqual(pool.waiterCount, 0)
        XCTAssertEqual(stranger.recreateCalls, 0)
    }

    func testWaiterPromotedOnlyOnceUntilReacquire() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        _ = pool.acquire(c) // waiter
        pool.release(a) // promotes c via tryRecreateWebView
        XCTAssertEqual(c.recreateCalls, 1)
        // Stub doesn't call back into acquire(), so the pool now has 1
        // lease (b) and an empty waiter list. Verify a fresh acquire on
        // c would succeed (free slot).
        XCTAssertTrue(pool.acquire(c))
        XCTAssertEqual(pool.leaseCount, 2)
    }

    // MARK: - 가시성 기반 lease (eager 스택 대응)

    func testOffScreenLeaseIsEvictedForANewcomer() {
        // eager 스택에서는 화면 밖 행도 계속 마운트돼 있다 — 슬롯이 도는
        // 유일한 길이 "화면 밖 lease 회수" 다. 이게 없으면 webm 이 3개
        // 이상인 글에서 셋째부터 영원히 포스터만 뜬다.
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        pool.notifyPaused(a)                 // a 가 화면 밖으로

        XCTAssertTrue(pool.acquire(c), "화면 밖 a 를 회수하고 c 에게 슬롯을 준다")
        XCTAssertEqual(a.evictCalls, 1, "a 는 WKWebView 를 내려놔야 함")
        XCTAssertEqual(pool.leaseCount, 2)
        XCTAssertEqual(pool.waiterCount, 0)
    }

    func testOnScreenLeasesAreNeverEvicted() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        _ = pool.acquire(a)
        _ = pool.acquire(b)

        XCTAssertFalse(pool.acquire(c), "둘 다 화면 안이면 회수 대상이 없다")
        XCTAssertEqual(a.evictCalls, 0)
        XCTAssertEqual(b.evictCalls, 0)
        XCTAssertEqual(pool.waiterCount, 1)
    }

    func testPauseHandsSlotToWaitingOnScreenView() {
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        _ = pool.acquire(c)                  // 대기열
        XCTAssertEqual(c.recreateCalls, 0)

        pool.notifyPaused(b)                 // b 가 화면 밖으로
        XCTAssertEqual(c.recreateCalls, 1, "대기 중이던 화면 안 뷰가 승격된다")
    }

    func testResumeMakesLeaseNonEvictable() {
        // 뷰포트 가장자리에서 잠깐 벗어났다 돌아온 webm 이, 뒤이어 들어온
        // 다른 webm 에게 슬롯을 뺏겨 화면 한가운데서 꺼지면 안 된다.
        let a = StubHolder("a")
        let b = StubHolder("b")
        let c = StubHolder("c")
        _ = pool.acquire(a)
        _ = pool.acquire(b)
        pool.notifyPaused(a)
        pool.notifyResumed(a)                // 다시 화면 안

        XCTAssertEqual(pool.pausedLeaseCount, 0)
        XCTAssertFalse(pool.acquire(c), "회수 가능한 lease 가 없다")
        XCTAssertEqual(a.evictCalls, 0)
    }

    func testResumeOnNonLeaseHolderIsNoOp() {
        // 이미 회수당한 뒤(webView 없음) 들어오는 resume 은 무시돼야 한다 —
        // 실제 경로에선 그때 tryRecreateWebView 로 재획득한다.
        let a = StubHolder("a")
        pool.notifyResumed(a)
        XCTAssertEqual(pool.leaseCount, 0)
        XCTAssertEqual(pool.waiterCount, 0)
    }
}
