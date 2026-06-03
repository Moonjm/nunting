import XCTest
@testable import nunting

@MainActor
final class VideoPlayerPoolTests: XCTestCase {

    /// Stub leaseholder — records the pool's eviction / promotion
    /// callbacks so tests can verify which lease the pool acts on
    /// without spinning up a real `AVPlayer`.
    private final class StubHolder: VideoPlayerPool.Leaseholder {
        let name: String
        private(set) var recreateCalls = 0
        private(set) var evictionCalls = 0
        init(_ name: String) { self.name = name }
        func tryRecreatePlayer() { recreateCalls += 1 }
        func releasePlayerForPoolEviction() { evictionCalls += 1 }
    }

    private var pool: VideoPlayerPool!

    override func setUp() async throws {
        try await super.setUp()
        pool = VideoPlayerPool.shared
        pool.resetForTesting()
    }

    override func tearDown() async throws {
        pool.resetForTesting()
        try await super.tearDown()
    }

    // MARK: - Baseline eviction policy

    func testAcquireGrantsUpToCap() {
        let holders = (0..<VideoPlayerPool.maxConcurrent).map { StubHolder("\($0)") }
        for h in holders { XCTAssertTrue(pool.acquire(h)) }
        XCTAssertEqual(pool.leaseCount, VideoPlayerPool.maxConcurrent)
        XCTAssertEqual(pool.waiterCount, 0)
    }

    func testAtCapAllPlayingDeniesAndQueues() {
        let a = StubHolder("a"), b = StubHolder("b"), c = StubHolder("c"), d = StubHolder("d")
        _ = pool.acquire(a); _ = pool.acquire(b); _ = pool.acquire(c)
        XCTAssertFalse(pool.acquire(d), "all 3 leases playing → 4th denied")
        XCTAssertEqual(pool.waiterCount, 1)
        XCTAssertEqual(a.evictionCalls, 0, "no playing lease evicted")
    }

    func testPausedLeaseIsEvictedWhenNewViewAcquires() {
        let a = StubHolder("a"), b = StubHolder("b"), c = StubHolder("c"), d = StubHolder("d")
        _ = pool.acquire(a); _ = pool.acquire(b); _ = pool.acquire(c)
        pool.notifyPaused(a)               // a scrolls off-screen
        XCTAssertTrue(pool.acquire(d), "d evicts the paused lease")
        XCTAssertEqual(a.evictionCalls, 1, "oldest paused lease (a) evicted")
        XCTAssertEqual(pool.leaseCount, 3)
        XCTAssertEqual(pool.pausedLeaseCount, 0)
    }

    // MARK: - Regression: scroll-up resume must protect the lease

    /// Core regression. A lease that paused at the viewport edge but
    /// kept its player alive, then resumed when scrolled back into view,
    /// must NOT be treated as eviction-eligible. Before the
    /// `notifyResumed` fix the lease stayed `isPaused == true`, so the
    /// next acquire evicted this on-screen, playing video — which then
    /// stalled on its poster because no visibility change re-fired
    /// `setPlaying`.
    func testResumedLeaseIsNotEvictable() {
        let a = StubHolder("a"), b = StubHolder("b"), c = StubHolder("c"), d = StubHolder("d")
        _ = pool.acquire(a); _ = pool.acquire(b); _ = pool.acquire(c)

        // a drifts to the viewport edge (player kept alive)…
        pool.notifyPaused(a)
        XCTAssertEqual(pool.pausedLeaseCount, 1)
        // …then scrolls back into view, reusing its live player.
        pool.notifyResumed(a)
        XCTAssertEqual(pool.pausedLeaseCount, 0, "resume clears the paused flag")

        // A new video now wants a slot. With every lease playing it must
        // be denied + queued, NOT granted by evicting the resumed `a`.
        XCTAssertFalse(pool.acquire(d), "all leases playing → new view queued")
        XCTAssertEqual(a.evictionCalls, 0, "resumed on-screen video must not be evicted")
        XCTAssertEqual(pool.leaseCount, 3)
        XCTAssertEqual(pool.waiterCount, 1)
    }

    /// Once resumed, the lease should sort as newest so a later genuine
    /// pause elsewhere is preferred for eviction over the resumed one.
    func testResumeRefreshesRecencyOverOtherPausedLease() {
        let a = StubHolder("a"), b = StubHolder("b"), c = StubHolder("c"), d = StubHolder("d")
        _ = pool.acquire(a); _ = pool.acquire(b); _ = pool.acquire(c)

        pool.notifyPaused(a)   // a paused (oldest)
        pool.notifyResumed(a)  // a back on screen → newest, active
        pool.notifyPaused(b)   // b now the only paused, off-screen

        XCTAssertTrue(pool.acquire(d))
        XCTAssertEqual(b.evictionCalls, 1, "the still-paused b is evicted")
        XCTAssertEqual(a.evictionCalls, 0, "the resumed a is spared")
    }

    func testResumeOnNonLeaseIsNoOp() {
        let stranger = StubHolder("stranger")
        pool.notifyResumed(stranger) // never acquired — must be safe
        XCTAssertEqual(pool.leaseCount, 0)
        XCTAssertEqual(pool.waiterCount, 0)
    }

    /// End-to-end "scroll up" shape: three playing videos, the bottom
    /// one drifts off and resumes as the user scrolls back, then a video
    /// entering from the top requests a slot. The entering video should
    /// queue (all visible/playing), and none of the on-screen videos
    /// should be torn down.
    func testScrollUpDoesNotStallVisibleVideo() {
        let top = StubHolder("top"), mid = StubHolder("mid"), bottom = StubHolder("bottom")
        _ = pool.acquire(top); _ = pool.acquire(mid); _ = pool.acquire(bottom)

        // bottom slips past the edge, then comes right back (fast-resume).
        pool.notifyPaused(bottom)
        pool.notifyResumed(bottom)

        // A new video scrolls in from the top.
        let incoming = StubHolder("incoming")
        XCTAssertFalse(pool.acquire(incoming), "no free/paused slot → queued, not stealing one")
        XCTAssertEqual(top.evictionCalls, 0)
        XCTAssertEqual(mid.evictionCalls, 0)
        XCTAssertEqual(bottom.evictionCalls, 0, "the resumed visible video keeps playing")
        XCTAssertEqual(pool.waiterCount, 1)
    }
}
