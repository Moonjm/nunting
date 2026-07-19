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
}
