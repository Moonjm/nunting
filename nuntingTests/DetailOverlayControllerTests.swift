import XCTest
@testable import nunting

/// State + transition tests for `DetailOverlayController`.
///
/// `show(_:)`'s "different post" branch defers an animation to the next
/// runloop via `DispatchQueue.main.async`, so tests that exercise that
/// branch wait one runloop tick before asserting on `offset`. The
/// keep-alive branch (`show` of the already-active post) commits
/// synchronously inside a `withAnimation`, so its assertions are
/// immediate.
@MainActor
final class DetailOverlayControllerTests: XCTestCase {

    // MARK: - Helpers

    /// Polls `offset` for up to `timeoutMs` until it equals `target`.
    /// `show(_:)`'s replace-path defers the animation through a Task +
    /// `Task.yield`; under XCTest's actor scheduler the yield-then-resume
    /// timing flakes around a single sleep boundary, so poll until
    /// settled instead of betting on one wall-clock window.
    private func waitForOffset(_ detail: DetailOverlayController, equals target: CGFloat, timeoutMs: Int = 500) async {
        let stepMs = 10
        let steps = max(timeoutMs / stepMs, 1)
        for _ in 0..<steps {
            if abs(detail.offset - target) < 0.01 { return }
            try? await Task.sleep(for: .milliseconds(stepMs))
        }
    }

    private func makePost(id: String = "test-1") -> Post {
        Post(
            id: id,
            site: .clien,
            boardID: "clien-news",
            title: "제목",
            author: "작성자",
            date: nil,
            dateText: "방금",
            commentCount: 0,
            url: URL(string: "https://www.clien.net/service/board/news/\(id)")!
        )
    }

    // MARK: - Initial state

    func testInitialStateIsHiddenWithNoActivePost() {
        let detail = DetailOverlayController()
        XCTAssertNil(detail.activePost)
        XCTAssertEqual(detail.offset, 0)
        XCTAssertEqual(detail.offsetBase, 0)
        XCTAssertFalse(detail.animating)
        XCTAssertEqual(detail.containerWidth, 0)
        // 컨테이너 측정 전엔 hit-test 허용 — 첫 layout 전 뷰가 dead 영역 안 되도록
        XCTAssertTrue(detail.allowsHitTesting)
        XCTAssertFalse(detail.isOverlayVisible)
    }

    // MARK: - show(_:)

    func testShowFirstPostSetsActiveAndAnimatesIn() async {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        let post = makePost()

        detail.show(post)

        XCTAssertEqual(detail.activePost?.id, post.id)
        // show 의 replace-path 는 Task + Task.yield 로 한 frame 지연 후
        // withAnimation { offset = 0 } 를 실행. 폴링으로 settle 확인.
        await waitForOffset(detail, equals: 0)
        XCTAssertEqual(detail.offset, 0, "yield 후 spring 이 visible(0) 로 commit")
    }

    func testShowSamePostKeepsActiveAndSlidesIn() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        let post = makePost()
        detail.activePost = post
        detail.offset = 400  // hidden

        detail.show(post)

        // 같은 post 이면 keep-alive path — withAnimation 동기 commit.
        XCTAssertEqual(detail.activePost?.id, post.id, "activePost 그대로")
        XCTAssertEqual(detail.offset, 0, "즉시 visible 로 spring")
    }

    func testShowDifferentPostReplacesActive() async {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        let first = makePost(id: "a")
        let second = makePost(id: "b")
        detail.activePost = first
        detail.offset = 0

        detail.show(second)

        XCTAssertEqual(detail.activePost?.id, "b", "다른 포스트면 activePost 즉시 swap")
        await waitForOffset(detail, equals: 0)
        XCTAssertEqual(detail.offset, 0)
    }

    // MARK: - hide()

    func testHideAnimatesOffScreenAndKeepsActivePost() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        detail.activePost = makePost()
        detail.offset = 0

        detail.hide()

        XCTAssertEqual(detail.offset, 400, "offset 은 containerWidth 로 spring (off-screen)")
        XCTAssertNotNil(detail.activePost,
                        "activePost 는 nil 안 됨 — 다음 forward-swipe 가 같은 인스턴스 재revealing")
    }

    // MARK: - updateContainerWidth

    func testUpdateContainerWidthPreservesHiddenState() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        detail.offset = 400  // fully hidden

        detail.updateContainerWidth(800)

        XCTAssertEqual(detail.containerWidth, 800)
        XCTAssertEqual(detail.offset, 800,
                       "회전/리사이즈로 width 가 늘어나도 hidden 상태 유지 — sliver 가 보이지 않게")
    }

    func testUpdateContainerWidthDoesNotMoveVisibleOverlay() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        detail.offset = 0  // fully visible

        detail.updateContainerWidth(800)

        XCTAssertEqual(detail.containerWidth, 800)
        XCTAssertEqual(detail.offset, 0,
                       "보이는 상태에선 width 변경이 offset 에 영향 없음")
    }

    func testUpdateContainerWidthAtPartialOffsetLeavesItAlone() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        detail.offset = 200  // mid-drag, partial reveal

        detail.updateContainerWidth(800)

        XCTAssertEqual(detail.containerWidth, 800)
        XCTAssertEqual(detail.offset, 200, "부분 reveal 중에는 offset 그대로 — drag 트래킹 깨면 안 됨")
    }

    // MARK: - shouldDismissSwipe + threshold

    func testSwipeDistanceThresholdCappedAt32() {
        let detail = DetailOverlayController()
        detail.containerWidth = 1024  // 8% = 81 — 32 로 캡됨
        XCTAssertEqual(detail.swipeDistanceThreshold, 32)
    }

    func testSwipeDistanceThresholdScalesAt8Percent() {
        let detail = DetailOverlayController()
        detail.containerWidth = 200  // 8% = 16
        XCTAssertEqual(detail.swipeDistanceThreshold, 16)
    }

    func testShouldDismissByDistanceOnly() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400  // threshold 32
        XCTAssertFalse(detail.shouldDismissSwipe(dx: 31, velocityX: 0), "임계 미만 + 정지")
        XCTAssertTrue(detail.shouldDismissSwipe(dx: 33, velocityX: 0), "임계 초과 → dismiss")
    }

    func testShouldDismissByVelocityOnly() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        XCTAssertFalse(detail.shouldDismissSwipe(dx: 0, velocityX: 119), "120 이하는 가속 부족")
        XCTAssertTrue(detail.shouldDismissSwipe(dx: 0, velocityX: 121),
                      "거의 안 움직였어도 빠른 flick 은 dismiss 의도로 인정")
    }

    // MARK: - Visibility predicates

    func testAllowsHitTestingWhenContainerNotMeasuredYet() {
        let detail = DetailOverlayController()
        detail.containerWidth = 0
        detail.offset = 0
        XCTAssertTrue(detail.allowsHitTesting,
                      "containerWidth 0 (측정 전) 일 땐 hit-test 허용 — 첫 frame 에서 dead view 안 되도록")
    }

    func testAllowsHitTestingWhenVisible() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        detail.offset = 0
        XCTAssertTrue(detail.allowsHitTesting)
    }

    func testDoesNotAllowHitTestingWhenFullyHidden() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        detail.offset = 400
        XCTAssertFalse(detail.allowsHitTesting,
                       "off-screen 상태에선 list 가 hit-test 받아야 함 — 숨은 overlay 가 가로채면 안 됨")
    }

    func testDoesNotAllowHitTestingWhenAlmostHidden() {
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        detail.offset = 399.7  // < 0.5 from edge
        XCTAssertFalse(detail.allowsHitTesting, "0.5pt 이내는 'hidden' 으로 분류 — 부동소수 jitter 흡수")
    }

    func testIsOverlayVisibleRequiresMeasuredContainer() {
        let detail = DetailOverlayController()
        detail.containerWidth = 0
        detail.offset = 0
        XCTAssertFalse(detail.isOverlayVisible,
                       "container 측정 전엔 'visible' 아님 — PostDetailView 의 디코드 게이팅이 false 받아야 함")
    }

    // MARK: - Task lifecycle

    func testShowFollowedByHideEndsHidden() async {
        // show 의 deferred animation 이 yield 후 fire 된다고 해도, 그 사이
        // hide() 가 호출됐다면 hide 가 요청한 hidden 상태로 정착해야 함.
        // 기존 구현은 deferred 가 hide 를 silently override 하는 race 가 있었음.
        let detail = DetailOverlayController()
        detail.containerWidth = 400
        let post = makePost()

        detail.show(post)
        detail.hide()
        await waitForOffset(detail, equals: 400)

        XCTAssertEqual(detail.offset, 400,
                       "show → hide 시퀀스의 최종 상태는 hidden — show 의 deferred animation 이 hide 를 override 하면 안 됨")
    }

    func testBeginAnimationLockReentryHonorsSecondCallFullDuration() async {
        // 첫 호출의 350ms 타이머가 두번째 호출 도중 만료돼서 두번째
        // lock 을 일찍 release 시키면, PostDetailView 의 inner scroll
        // lock 이 spring settle 중간에 풀려 contentOffset drift 가
        // 발생함. 이 테스트는 첫 호출 후 100ms 뒤에 두번째 호출 → 첫
        // 호출의 deadline (t=350) 직후 시점 (t=400) 에 animating 이
        // 여전히 true 인지 확인. 두번째 호출의 deadline 은 t=450.
        let detail = DetailOverlayController()
        detail.beginAnimationLock()
        try? await Task.sleep(for: .milliseconds(100))
        detail.beginAnimationLock()  // 첫 호출의 timer 를 cancel + 새로 350ms
        XCTAssertTrue(detail.animating)

        // 첫 호출 deadline 직후 (t=400) — 두번째 호출 deadline (t=450) 전.
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(detail.animating,
                      "두번째 호출의 350ms 가 끝나기 전엔 첫 호출의 만료 timer 가 lock 을 release 하면 안 됨")

        // 두번째 호출 deadline 이후 — release 됐어야 함.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(detail.animating,
                       "두번째 호출의 350ms 후엔 정상 release")
    }
}
