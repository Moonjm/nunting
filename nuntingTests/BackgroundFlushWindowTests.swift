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

        let ticket = window.enter()
        XCTAssertTrue(window.isOpenForTesting)
        XCTAssertEqual(begins(), 1)
        XCTAssertEqual(ends(), 0)

        window.leave(ticket)
        XCTAssertFalse(window.isOpenForTesting)
        XCTAssertEqual(ends(), 1)
    }

    func testOverlappingUploadsKeepTheWindowOpenUntilTheLastOne() {
        let (window, begins, ends, _) = makeWindow()

        let first = window.enter()
        let second = window.enter()
        XCTAssertEqual(begins(), 1, "겹친 업로드가 창을 두 번 열었다")

        window.leave(first)
        XCTAssertTrue(window.isOpenForTesting,
                      "아직 날고 있는 업로드가 있는데 창이 닫혔다")
        XCTAssertEqual(ends(), 0)

        window.leave(second)
        XCTAssertFalse(window.isOpenForTesting)
        XCTAssertEqual(ends(), 1)
    }

    /// OS 가 시간을 회수하면 남은 업로드가 있어도 반드시 닫아야 한다 —
    /// 안 닫으면 앱이 강제 종료된다.
    func testExpirationClosesTheWindowEvenWithUploadsInFlight() {
        let (window, _, ends, expire) = makeWindow()

        _ = window.enter()
        _ = window.enter()
        expire()

        XCTAssertFalse(window.isOpenForTesting)
        XCTAssertEqual(ends(), 1)
        XCTAssertEqual(window.pendingForTesting, 0, "만료 후에도 대기 수가 남았다")
    }

    /// 만료로 이미 닫힌 뒤 도착하는 `leave()` 가 창을 한 번 더 닫으면
    /// `endBackgroundTask` 가 잘못된 식별자로 두 번 불린다.
    func testLeaveAfterExpirationDoesNotCloseTwice() {
        let (window, _, ends, expire) = makeWindow()

        let ticket = window.enter()
        expire()
        window.leave(ticket)

        XCTAssertEqual(ends(), 1, "만료 뒤의 leave 가 창을 한 번 더 닫았다")
    }

    /// 만료로 창이 강제로 닫힌 뒤 그때 날고 있던 업로드가 뒤늦게 끝난다.
    /// 그 사이 새 flush 가 창을 열었다면, 그 뒤늦은 완료가 **새 창**의
    /// 카운터를 깎아 아직 보내는 중인데 창이 닫히면 안 된다 — 이 타입이
    /// 막으려던 유실이 그대로 재현된다.
    func testCompletionFromAnExpiredGenerationDoesNotCloseTheNextWindow() {
        let (window, begins, ends, expire) = makeWindow()

        let stale = window.enter()
        expire()
        XCTAssertEqual(ends(), 1)

        let fresh = window.enter()
        XCTAssertEqual(begins(), 2, "새 flush 가 창을 다시 열지 않았다")

        window.leave(stale)
        XCTAssertTrue(window.isOpenForTesting,
                      "만료된 세대의 완료가 새 창을 닫았다")
        XCTAssertEqual(ends(), 1)

        window.leave(fresh)
        XCTAssertFalse(window.isOpenForTesting)
        XCTAssertEqual(ends(), 2)
    }

    /// 정상 종료로 닫힌 세대의 영수증도 마찬가지로 무효다 — 같은 영수증을
    /// 두 번 넘겨도 다음 창을 건드리지 못한다.
    func testReusingATicketAfterNormalCloseIsIgnored() {
        let (window, _, ends, _) = makeWindow()

        let ticket = window.enter()
        window.leave(ticket)
        XCTAssertEqual(ends(), 1)

        _ = window.enter()
        window.leave(ticket)

        XCTAssertTrue(window.isOpenForTesting, "이미 쓴 영수증이 새 창을 닫았다")
        XCTAssertEqual(ends(), 1)
    }
}
