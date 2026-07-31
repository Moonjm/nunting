import XCTest
import SwiftUI
import UIKit
@testable import nunting

/// 백드래그 중 스크롤 잠금이 **SwiftUI 트리를 건드리지 않고** 걸리는지.
///
/// 종전 방식(`.scrollDisabled(isScrollingBlocked)`)은 그 값이 상세 뷰의
/// Equatable 입력이라, 드래그 시작/끝마다 상세 전체가 다시 평가되며 댓글 행
/// 높이를 전부 다시 쟀다 — 기기 정체 스택에 `SelectableRichText.sizeThatFits`
/// 가 찍힌 자리다.
@MainActor
final class DetailScrollLockTests: XCTestCase {

    private func hostedScrollView() -> (UIWindow, UIScrollView) {
        let host = UIHostingController(
            rootView: ScrollView {
                VStack {
                    DetailScrollLockGate()
                    Color.gray.frame(height: 4000)
                }
            }
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        settle(window)
        return (window, Self.firstScrollView(host.view)!)
    }

    private func settle(_ view: UIView?, turns: Int = 4) {
        for _ in 0..<turns {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            CATransaction.flush()
            view?.setNeedsLayout()
            view?.layoutIfNeeded()
        }
    }

    private static func firstScrollView(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(sub) { return found }
        }
        return nil
    }

    override func tearDown() async throws {
        DetailScrollLock.shared.isLocked = false
        try await super.tearDown()
    }

    /// 잠그면 감싸고 있는 스크롤 뷰가 실제로 멈춘다.
    func testLockingDisablesTheEnclosingScrollView() {
        let (window, scrollView) = hostedScrollView()
        defer { window.isHidden = true }
        XCTAssertTrue(scrollView.isScrollEnabled)

        DetailScrollLock.shared.isLocked = true
        settle(window)

        XCTAssertFalse(scrollView.isScrollEnabled, "잠갔는데 스크롤이 살아 있다")
    }

    /// 풀면 원래대로 — 스프링 정착이 끝난 뒤 스크롤이 다시 살아야 한다.
    func testUnlockingRestoresScrolling() {
        let (window, scrollView) = hostedScrollView()
        defer { window.isHidden = true }

        DetailScrollLock.shared.isLocked = true
        settle(window)
        DetailScrollLock.shared.isLocked = false
        settle(window)

        XCTAssertTrue(scrollView.isScrollEnabled, "잠금을 풀었는데 스크롤이 죽어 있다")
    }

    /// 애니메이션 락이 풀릴 때 스크롤 잠금도 같이 풀린다 — 이 배선이 끊기면
    /// 백드래그를 취소한 뒤 상세가 영영 스크롤되지 않는다.
    func testAnimationLockReleaseUnlocksScrolling() async {
        DetailScrollLock.shared.isLocked = true
        DetailOverlayController.shared.beginAnimationLock()

        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertFalse(DetailScrollLock.shared.isLocked,
                       "정착이 끝났는데 스크롤 잠금이 남았다")
    }
}
