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

    /// 정착 스프링이 도는 도중에 다시 잡으면 손가락을 따라가야 한다.
    /// 애니메이션을 안 걷으면(또는 엉뚱한 키를 걷으면) 프레젠테이션 레이어의
    /// 스프링이 살아남아 직접 대입과 싸운다 — 화면이 손가락과 다른 곳으로 튄다.
    func testTrackingInterruptsARunningAnimation() {
        let (transform, target) = makeTarget()
        transform.animate(to: 393)
        XCTAssertFalse(target.layer.animationKeys()?.isEmpty ?? true,
                       "스프링이 시작되지 않아 이 검증이 무의미하다")

        transform.track(100)

        XCTAssertTrue(target.layer.animationKeys()?.isEmpty ?? true,
                      "드래그를 다시 잡았는데 스프링이 살아 있다")
        XCTAssertEqual(target.transform.tx, 100, accuracy: 0.01)
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

    /// 글을 열면 오버레이가 **제자리(0)에 정착**해야 한다. 실제로 터진 회귀가
    /// 이것이다 — 상세가 잠깐 떴다가 옆으로 사라진 채 남았고, 논리 상태는
    /// "보이는 중"이라 뒤쪽 목록까지 먹통이 됐다.
    ///
    /// 타깃 뷰를 테스트가 심지 않는 이유: 이 테스트 번들의 호스트는 **앱 자체**라,
    /// `show()` 가 진짜 오버레이를 만들고 그쪽이 `shared.target` 을 가져간다.
    /// 그래서 심어 둔 가짜 뷰가 아니라 실제로 움직인 뷰를 확인한다.
    func testShowingAPostSettlesTheOverlayInPlace() async {
        let controller = DetailOverlayController.shared
        let previousPost = controller.activePost
        defer { controller.activePost = previousPost }
        controller.updateContainerWidth(393)
        controller.hide()

        controller.show(
            Post(
                id: "overlay-settle-test",
                site: .clien,
                boardID: "park",
                title: "새 글",
                author: "",
                date: nil,
                dateText: "",
                commentCount: 0,
                url: URL(string: "https://www.clien.net/service/board/park/2")!
            )
        )
        try? await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(controller.offset, 0, accuracy: 0.01)
        XCTAssertEqual(DetailOverlayTransform.shared.offset, 0, accuracy: 0.01,
                       "글을 열었는데 변환이 제자리로 오지 않았다")
        if let moved = DetailOverlayTransform.shared.target {
            XCTAssertEqual(moved.transform.tx, 0, accuracy: 0.5,
                           "실제 오버레이 뷰가 제자리로 오지 않았다")
        }
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
