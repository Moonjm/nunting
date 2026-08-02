import XCTest
import CoreGraphics
@testable import nunting

/// 백드래그 방향 판정 회귀 테스트. 기존 판정(w≥h 동률 가로 우선, 10pt)은
/// 살짝 대각선으로 시작한 세로 스크롤을 백드래그로 잠가 스크롤까지 얼렸다
/// ("위로 스크롤이 뒤로가기로 인식") — 가로 판정에 명확한 우세(1.5배)를
/// 요구하고 동률·애매한 대각선은 미정/세로(스크롤 우선)로 남긴다.
final class DetailBackDragLockTests: XCTestCase {

    private func decide(_ w: CGFloat, _ h: CGFloat) -> DetailBackDrag.DragAxis? {
        DetailBackDrag.lockDecision(translation: CGSize(width: w, height: h))
    }

    func testClearHorizontalRightLocksBackDrag() {
        XCTAssertEqual(decide(20, 0), .horizontalRight)
        XCTAssertEqual(decide(30, 15), .horizontalRight, "1.5배 초과 우세면 가로")
    }

    func testClearVerticalLocksScroll() {
        XCTAssertEqual(decide(0, 20), .vertical)
        XCTAssertEqual(decide(0, -20), .vertical, "위로 스크롤(음수)도 세로")
    }

    /// 기존 오인식 케이스 — 대각선 위 스크롤 초입(가로 11, 세로 10)이
    /// 가로로 잠기던 입력. 이제 미정으로 남아 더 움직인 뒤 판정한다.
    func testSlightlyHorizontalDiagonalStaysUndecided() {
        XCTAssertNil(decide(11, -10))
        XCTAssertNil(decide(14, 10), "1.5배 미만 우세는 아직 미정")
    }

    func testTieGoesToVertical() {
        XCTAssertEqual(decide(14, -14), .vertical, "동률은 스크롤 우선")
    }

    func testLeftHorizontalIsDistinguished() {
        XCTAssertEqual(decide(-20, 5), .horizontalLeft, "좌측 가로는 닫기와 무관 — 양보 분기")
    }

    func testBelowGateStaysUndecided() {
        XCTAssertNil(decide(8, 3), "이동량이 게이트 미만이면 미정")
        XCTAssertNil(decide(3, 8))
    }

    // MARK: - 스프링을 다시 잡을 때의 기준선

    /// 잡은 그 자리에서 시작해야 한다 — 이동량이 0 이면 화면도 그대로.
    /// 이게 깨지면 스프링 도중 다시 잡는 순간 오버레이가 목적지(또는 0)로
    /// 튄 뒤에 손가락을 따라온다.
    func testTrackingStartsFromWhereTheOverlayWasGrabbed() {
        let offset = DetailBackDrag.trackedOffset(
            startOffset: 180, translation: 40, baseline: 40, containerWidth: 393
        )
        XCTAssertEqual(offset, 180, accuracy: 0.01)
    }

    /// 잡은 뒤의 이동량은 그 자리에 더해진다.
    func testTrackingAddsFingerTravelToTheGrabPoint() {
        let offset = DetailBackDrag.trackedOffset(
            startOffset: 180, translation: 100, baseline: 40, containerWidth: 393
        )
        XCTAssertEqual(offset, 240, accuracy: 0.01)
    }

    /// 평소(정지 상태에서 잡기)엔 0 에서 시작하므로 종전과 같다.
    func testTrackingFromRestBehavesAsBefore() {
        let offset = DetailBackDrag.trackedOffset(
            startOffset: 0, translation: 60, baseline: 12, containerWidth: 393
        )
        XCTAssertEqual(offset, 48, accuracy: 0.01)
    }

    /// 화면 폭 안으로 자르고, 되돌리는 방향(음수)으로는 넘어가지 않는다.
    func testTrackingClampsToTheScreen() {
        XCTAssertEqual(
            DetailBackDrag.trackedOffset(
                startOffset: 300, translation: 400, baseline: 0, containerWidth: 393
            ),
            393, accuracy: 0.01
        )
        XCTAssertEqual(
            DetailBackDrag.trackedOffset(
                startOffset: 50, translation: -200, baseline: 0, containerWidth: 393
            ),
            0, accuracy: 0.01
        )
    }

    // MARK: - 배선: 잡은 자리에서 이어지는가

    /// 스프링이 도는 중에 다시 잡으면 **그 순간 보이던 자리**에서 이어져야
    /// 한다. 규칙(`trackedOffset`)이 맞아도 시작점을 안 넘기면(0 을 쓰면)
    /// 화면이 목적지로 튄 뒤 손가락을 따라온다 — 최근 회귀가 전부 이런
    /// "규칙은 맞는데 배선이 빠진" 자리였다.
    @MainActor
    func testRegrabbingMidSpringContinuesFromTheVisiblePosition() {
        let detail = DetailOverlayController.shared
        let transform = DetailOverlayTransform.shared
        let target = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        transform.target = target
        let previousVisible = transform.visibleTransform
        defer {
            transform.target = nil
            transform.visibleTransform = previousVisible
        }
        detail.updateContainerWidth(393)
        // 닫히는 스프링이 180pt 지점을 지나는 중이라고 하자.
        transform.snap(to: 0)
        transform.visibleTransform = { _ in CGAffineTransform(translationX: 180, y: 0) }

        let drag = DetailBackDrag()
        drag.beginHorizontalDrag(translationWidth: 14)

        XCTAssertEqual(target.transform.tx, 180, accuracy: 0.5,
                       "다시 잡는 순간 화면이 튀었다")

        // 손가락을 30pt 더 끌면 그 자리에서 30pt 만 움직인다.
        transform.visibleTransform = previousVisible
        drag.moveHorizontalDrag(translationWidth: 44)

        XCTAssertEqual(target.transform.tx, 210, accuracy: 0.5,
                       "이동량이 잡은 자리에 더해지지 않았다")
    }
}
