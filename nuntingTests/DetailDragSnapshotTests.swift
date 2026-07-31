import XCTest
import UIKit
@testable import nunting

/// 백드래그 스냅샷(`DetailDragSnapshot`)의 수명 계약.
///
/// 스냅샷이 살아있는 상세를 가리는 물건이라, 너무 일찍 걷으면 정착 중 화면이
/// 튀고 너무 늦게 걷으면 다음 글 위에 지난 글 그림이 남는다. 양쪽 다 사용자
/// 눈에 그대로 보이는 결함이라 경계 조건을 고정한다.
@MainActor
final class DetailDragSnapshotTests: XCTestCase {

    /// 스냅샷을 뜰 수 있는 실제 렌더 대상 — 창에 올라간 뷰라야
    /// `snapshotView(afterScreenUpdates:)` 가 뷰를 돌려준다.
    private func makeSource() -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let source = UIView(frame: window.bounds)
        source.backgroundColor = .systemBackground
        let host = UIViewController()
        host.view.addSubview(source)
        window.rootViewController = host
        // `snapshotView(afterScreenUpdates:)` 는 이미 렌더된 결과를 재사용하는
        // API 라 한 번도 그려진 적 없는 창에서는 아무것도 돌려주지 않는다.
        // 키 윈도우로 올리고 커밋을 한 번 돌려 렌더를 성립시킨다.
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return (window, source)
    }

    func testCaptureProvidesASnapshotView() {
        let store = DetailDragSnapshot()
        let (window, source) = makeSource()
        defer { window.isHidden = true }

        store.capture(from: source, currentOffset: 0)
        XCTAssertNotNil(store.view, "드래그 시작인데 스냅샷을 못 떴다")
    }

    /// 이미 밀려 있는 상태(애니메이션 도중 다시 잡은 경우)에서 뜬 스냅샷은
    /// 그 이동량이 이미 찍혀 있어, 거기에 offset 을 또 걸면 두 배로 밀린다.
    func testCaptureSkippedWhenOverlayIsAlreadyOffset() {
        let store = DetailDragSnapshot()
        let (window, source) = makeSource()
        defer { window.isHidden = true }

        store.capture(from: source, currentOffset: 120)
        XCTAssertNil(store.view, "이미 밀린 화면을 스냅샷으로 떴다 — 이중 이동")
    }

    /// 스냅샷을 못 떠도(캡처 실패) 기능은 그대로여야 한다 — 살아있는 계층이
    /// 종전처럼 움직이고, 히치만 남는다.
    func testCaptureFailureLeavesNoSnapshot() {
        let store = DetailDragSnapshot()
        store.capture(from: nil, currentOffset: 0)
        XCTAssertNil(store.view)
    }

    /// 드래그가 겹쳐 들어와도 첫 스냅샷을 유지한다(중간에 갈아끼우면 그
    /// 프레임에 화면이 튄다).
    func testSecondCaptureKeepsTheFirstSnapshot() {
        let store = DetailDragSnapshot()
        let (window, source) = makeSource()
        defer { window.isHidden = true }

        store.capture(from: source, currentOffset: 0)
        let first = store.view
        store.capture(from: source, currentOffset: 0)
        XCTAssertTrue(store.view === first)
    }

    func testReleaseNowClearsImmediately() {
        let store = DetailDragSnapshot()
        let (window, source) = makeSource()
        defer { window.isHidden = true }

        store.capture(from: source, currentOffset: 0)
        store.releaseNow()
        XCTAssertNil(store.view)
    }

    /// 손을 뗀 직후에는 아직 남아 있어야 한다 — 스프링(0.32s)과 애니메이션
    /// 락(350ms)이 도는 동안 화면을 갈아끼우면 정착이 튄다.
    func testReleaseAfterSettleKeepsSnapshotDuringTheSpring() async {
        let store = DetailDragSnapshot()
        let (window, source) = makeSource()
        defer { window.isHidden = true }

        store.capture(from: source, currentOffset: 0)
        store.releaseAfterSettle()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(store.view, "정착 도중에 스냅샷이 걷혔다")
    }

    func testReleaseAfterSettleClearsOnceSettled() async {
        let store = DetailDragSnapshot()
        let (window, source) = makeSource()
        defer { window.isHidden = true }

        store.capture(from: source, currentOffset: 0)
        store.releaseAfterSettle()
        try? await Task.sleep(for: DetailDragSnapshot.settleWindow + .milliseconds(200))
        XCTAssertNil(store.view, "정착이 끝났는데 스냅샷이 남았다")
    }

    /// 정착 대기 중에 새 드래그가 시작되면, 대기 중이던 해제가 그 드래그
    /// 도중에 터져 화면이 튀면 안 된다.
    func testNewCaptureCancelsAPendingRelease() async {
        let store = DetailDragSnapshot()
        let (window, source) = makeSource()
        defer { window.isHidden = true }

        store.capture(from: source, currentOffset: 0)
        store.releaseAfterSettle()
        store.releaseNow()                       // 첫 드래그 정착 완료
        store.capture(from: source, currentOffset: 0)  // 곧바로 다음 드래그
        try? await Task.sleep(for: DetailDragSnapshot.settleWindow + .milliseconds(200))

        XCTAssertNotNil(store.view, "지난 드래그의 해제 타이머가 새 스냅샷을 걷었다")
    }

    /// 정착 대기가 끝나기 전에 다음 글을 열면 스냅샷이 새 상세를 덮는다 —
    /// 여는 쪽(`DetailOverlayController.show`)이 즉시 걷어야 한다.
    func testShowingAnotherPostClearsTheSharedSnapshot() {
        let (window, source) = makeSource()
        defer { window.isHidden = true }
        let controller = DetailOverlayController.shared
        let previousPost = controller.activePost
        defer { controller.activePost = previousPost }

        DetailDragSnapshot.shared.capture(from: source, currentOffset: 0)
        XCTAssertNotNil(DetailDragSnapshot.shared.view)

        controller.show(
            Post(
                id: "snapshot-test",
                site: .clien,
                boardID: "park",
                title: "다음 글",
                author: "",
                date: nil,
                dateText: "",
                commentCount: 0,
                url: URL(string: "https://www.clien.net/service/board/park/1")!
            )
        )

        XCTAssertNil(DetailDragSnapshot.shared.view, "다음 글 위에 지난 글 스냅샷이 남았다")
    }
}
