import XCTest
import UIKit
@testable import nunting

/// `BackgroundFlushWindow` 의 계수 계약.
///
/// 회귀 대상: flush 는 백그라운드 진입(`onBackground`)과 버퍼 포화
/// (`flushThreshold`) 양쪽에서 불려 두 업로드가 겹칠 수 있다. 창을 단순
/// 열기/닫기로 두면 먼저 끝난 쪽이 아직 날고 있는 쪽의 창까지 닫아, 정작
/// 지키려던 배치가 다시 증발한다.
@MainActor
final class BackgroundFlushWindowTests: XCTestCase {

    /// 실제 `UIApplication` 없이 primitive 만 스파이로 갈아끼운 창.
    private func makeWindow() -> (BackgroundFlushWindow, () -> Int, () -> Int, () -> Void) {
        let window = BackgroundFlushWindow()
        var begins = 0
        var ends = 0
        var expire: (@MainActor () -> Void)?
        window.beginTask = { handler in
            begins += 1
            expire = handler
            return UIBackgroundTaskIdentifier(rawValue: 1)
        }
        window.endTask = { _ in ends += 1 }
        return (window, { begins }, { ends }, { expire?() })
    }

    func testSingleUploadOpensAndClosesOnce() {
        let (window, begins, ends, _) = makeWindow()

        window.enter()
        XCTAssertTrue(window.isOpenForTesting)
        XCTAssertEqual(begins(), 1)
        XCTAssertEqual(ends(), 0)

        window.leave()
        XCTAssertFalse(window.isOpenForTesting)
        XCTAssertEqual(ends(), 1)
    }

    func testOverlappingUploadsKeepTheWindowOpenUntilTheLastOne() {
        let (window, begins, ends, _) = makeWindow()

        window.enter()
        window.enter()
        XCTAssertEqual(begins(), 1, "겹친 업로드가 창을 두 번 열었다")

        window.leave()
        XCTAssertTrue(window.isOpenForTesting,
                      "아직 날고 있는 업로드가 있는데 창이 닫혔다")
        XCTAssertEqual(ends(), 0)

        window.leave()
        XCTAssertFalse(window.isOpenForTesting)
        XCTAssertEqual(ends(), 1)
    }

    /// OS 가 시간을 회수하면 남은 업로드가 있어도 반드시 닫아야 한다 —
    /// 안 닫으면 앱이 강제 종료된다.
    func testExpirationClosesTheWindowEvenWithUploadsInFlight() {
        let (window, _, ends, expire) = makeWindow()

        window.enter()
        window.enter()
        expire()

        XCTAssertFalse(window.isOpenForTesting)
        XCTAssertEqual(ends(), 1)
        XCTAssertEqual(window.pendingForTesting, 0, "만료 후에도 대기 수가 남았다")
    }

    /// 만료로 이미 닫힌 뒤 도착하는 `leave()` 가 창을 한 번 더 닫으면
    /// `endBackgroundTask` 가 잘못된 식별자로 두 번 불린다.
    func testLeaveAfterExpirationDoesNotCloseTwice() {
        let (window, _, ends, expire) = makeWindow()

        window.enter()
        expire()
        window.leave()

        XCTAssertEqual(ends(), 1, "만료 뒤의 leave 가 창을 한 번 더 닫았다")
    }

    /// 시작한 적 없는 업로드의 `leave()` 는 아무것도 하지 않는다.
    func testUnbalancedLeaveIsIgnored() {
        let (window, begins, ends, _) = makeWindow()

        window.leave()

        XCTAssertEqual(begins(), 0)
        XCTAssertEqual(ends(), 0)
    }
}
