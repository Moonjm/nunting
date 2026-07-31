import XCTest
import SwiftUI
import UIKit
@testable import nunting

/// 상세 오버레이 위치를 UIKit 레이어 변환이 소유한다는 계약.
///
/// 왜 이 계약이 중요한가: 위치를 SwiftUI 상태로 두면 드래그가 프레임마다 그
/// 값을 쓰고, 그 값을 읽는 트리의 디스플레이 리스트가 통째로 다시 그려진다.
/// 기기 스택이 그 순간을 잡았다 — `CGGlyphBuilderLockBitmaps`(글리프 재래스터화)
/// 아래 `CGDisplayListDrawInContextDelegate`. 그래서 드래그 중에는 **SwiftUI
/// 상태를 건드리지 않고** 변환만 옮긴다.
@MainActor
final class DetailOverlayTransformTests: XCTestCase {

    private func makeTarget() -> (DetailOverlayTransform, UIView) {
        let transform = DetailOverlayTransform()
        let target = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        transform.target = target
        return (transform, target)
    }

    func testTrackMovesTheTargetImmediately() {
        let (transform, target) = makeTarget()
        transform.track(120)
        XCTAssertEqual(target.transform.tx, 120, accuracy: 0.01)
        XCTAssertEqual(transform.offset, 120, accuracy: 0.01)
    }

    func testSnapMovesWithoutAnimation() {
        let (transform, target) = makeTarget()
        transform.snap(to: 393)
        XCTAssertEqual(target.transform.tx, 393, accuracy: 0.01)
    }

    /// 스프링이 끝나면 목표 위치에 정확히 도달해야 한다 — 중간값에서 멈추면
    /// 오버레이가 화면에 걸친 채 남는다.
    func testAnimateSettlesAtTheTarget() async {
        let (transform, target) = makeTarget()
        transform.animate(to: 393)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(target.transform.tx, 393, accuracy: 0.5)
    }

    /// 논리 상태(`offset`)는 변환이 걸리기 전에 이미 갱신돼야 한다 — 애니메이션이
    /// 도는 동안에도 "지금 닫히는 중" 을 읽는 쪽(가시성 판정 등)이 옳은 값을 본다.
    func testOffsetUpdatesBeforeTheAnimationFinishes() {
        let (transform, _) = makeTarget()
        transform.animate(to: 393)
        XCTAssertEqual(transform.offset, 393, accuracy: 0.01)
    }

    /// 대상이 없을 때(오버레이가 아직/이미 없는 순간)도 논리 위치는 유지되고
    /// 크래시하지 않아야 한다.
    func testWorksWithoutATarget() {
        let transform = DetailOverlayTransform()
        transform.track(50)
        transform.snap(to: 100)
        XCTAssertEqual(transform.offset, 100, accuracy: 0.01)
    }

    /// **드래그 중에는 SwiftUI 상태를 건드리지 않는다.** 이 분리가 깨지면
    /// (예: track 이 컨트롤러 offset 도 쓰면) 프레임마다 트리가 다시 그려지는
    /// 원래 문제로 정확히 되돌아간다.
    func testTrackingDoesNotTouchTheControllerState() {
        let (transform, _) = makeTarget()
        let controller = DetailOverlayController.shared
        let before = controller.offset

        transform.track(77)

        XCTAssertEqual(controller.offset, before, accuracy: 0.01,
                       "드래그 추적이 SwiftUI 상태를 건드렸다")
    }

    // MARK: - 컨트롤러가 변환을 몰고 간다

    func testHideDrivesTheSharedTransform() async {
        let controller = DetailOverlayController.shared
        let target = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        DetailOverlayTransform.shared.target = target
        defer { DetailOverlayTransform.shared.target = nil }
        controller.updateContainerWidth(393)

        controller.hide()
        XCTAssertEqual(controller.offset, 393, accuracy: 0.01)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(target.transform.tx, 393, accuracy: 0.5, "닫기가 변환을 안 옮겼다")
    }

    func testSettleBackReturnsToZero() async {
        let controller = DetailOverlayController.shared
        let target = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        DetailOverlayTransform.shared.target = target
        defer { DetailOverlayTransform.shared.target = nil }
        controller.updateContainerWidth(393)
        DetailOverlayTransform.shared.track(200)

        controller.settleBack()
        XCTAssertEqual(controller.offset, 0, accuracy: 0.01)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(target.transform.tx, 0, accuracy: 0.5, "복귀가 변환을 안 되돌렸다")
    }

    /// 회전 등으로 폭이 바뀔 때, 숨겨져 있던 오버레이는 새 폭만큼 밖에 있어야
    /// 한다 — 안 그러면 오른쪽에 한 조각이 남는다.
    func testContainerWidthChangeKeepsAHiddenOverlayOffscreen() {
        let controller = DetailOverlayController.shared
        let target = UIView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        DetailOverlayTransform.shared.target = target
        defer { DetailOverlayTransform.shared.target = nil }

        controller.updateContainerWidth(393)
        controller.hide()
        controller.updateContainerWidth(800)

        XCTAssertEqual(controller.offset, 800, accuracy: 0.01)
        XCTAssertEqual(target.transform.tx, 800, accuracy: 0.5)
    }
}
