import XCTest
import SwiftUI
import UIKit
@testable import nunting

/// 상세를 자체 호스팅 컨트롤러에 담는 상자(`DetailOverlayHost`)의 배치·터치 계약.
///
/// 회귀 대상(실제로 터진 것): 상세가 잠깐 떴다가 옆으로 사라지고, 그 뒤 목록이
/// 통째로 먹통이 됐다. 원인 둘 —
///  1) 자식을 레이아웃 전 프레임 + autoresizing 으로 붙여 크기가 어긋났다.
///  2) 컨테이너가 화면 전체를 덮은 채, 상세가 변환으로 비켜난 자리의 터치까지
///     삼켰다(투명해도 UIView 는 자기 영역의 터치를 먹는다).
@MainActor
final class DetailOverlayHostTests: XCTestCase {

    private func hostedOverlay() -> (UIWindow, DetailOverlayContainerController<AnyView>) {
        let controller = DetailOverlayContainerController(
            rootView: AnyView(Color.blue.frame(maxWidth: .infinity, maxHeight: .infinity))
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        return (window, controller)
    }

    /// 자식(상세)은 레이아웃 타이밍과 무관하게 컨테이너를 꽉 채워야 한다.
    func testHostedViewFillsTheContainer() {
        let (window, controller) = hostedOverlay()
        defer { window.isHidden = true }

        XCTAssertEqual(controller.movableView.frame, controller.view.bounds)
    }

    /// 상세가 제자리에 있으면 그 위 터치는 상세가 받는다.
    func testTouchesLandOnTheOverlayWhenItIsInPlace() {
        let (window, controller) = hostedOverlay()
        defer { window.isHidden = true }
        controller.movableView.transform = .identity

        let hit = controller.view.hitTest(CGPoint(x: 200, y: 400), with: nil)
        XCTAssertNotNil(hit)
        XCTAssertTrue(hit === controller.movableView || hit?.isDescendant(of: controller.movableView) == true)
    }

    /// 상세가 화면 밖으로 비켜났으면 그 자리 터치는 **통과**해야 한다 —
    /// 안 그러면 뒤에 있는 목록이 통째로 먹통이 된다.
    func testTouchesPassThroughWhenTheOverlayIsMovedAway() {
        let (window, controller) = hostedOverlay()
        defer { window.isHidden = true }
        controller.movableView.transform = CGAffineTransform(translationX: 393, y: 0)
        window.layoutIfNeeded()

        XCTAssertNil(
            controller.view.hitTest(CGPoint(x: 200, y: 400), with: nil),
            "비켜난 상세 자리의 터치를 컨테이너가 삼켰다"
        )
    }

    /// 부분적으로 걸쳐 있으면(드래그 도중) 상세가 있는 쪽만 받는다.
    func testPartiallyDraggedOverlayOnlyTakesItsOwnArea() {
        let (window, controller) = hostedOverlay()
        defer { window.isHidden = true }
        controller.movableView.transform = CGAffineTransform(translationX: 200, y: 0)
        window.layoutIfNeeded()

        XCTAssertNotNil(controller.view.hitTest(CGPoint(x: 300, y: 400), with: nil),
                        "상세가 덮고 있는 자리인데 통과시켰다")
        XCTAssertNil(controller.view.hitTest(CGPoint(x: 50, y: 400), with: nil),
                     "상세가 비켜난 자리인데 삼켰다")
    }
}
