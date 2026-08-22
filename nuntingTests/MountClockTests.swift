import XCTest
import SwiftUI
@testable import nunting

/// `MountClock` — 표시 계측 기산점을 마운트 수명에 묶는 래퍼.
///
/// 못 박는 건 두 가지고, 둘 다 계측 정확도의 전제다:
///  1. 내용이 만들어지는 시점엔 기산점이 **없다**. SD 는 메모리 히트를 뷰 생성
///     도중 동기로 콜백하는데, 그건 실제로 기다림이 0 인 경우라 0ms 로 실려야 한다.
///  2. 리마운트하면 **새 시계**를 받는다. 이전 마운트의 시각이 넘어오면 재등장이
///     "최초 등장 이후 전부" 로 부풀어 p50/p90 이 통째로 오염된다.
@MainActor
final class MountClockTests: XCTestCase {

    private final class Recorder {
        /// 빌드 시점(=동기 콜백이 보는 상태)의 (시계, 그때의 기산점).
        var builds: [(clock: LoadClock, startedAt: Date?)] = []

        /// 등장 순서를 유지한 채 중복 제거 — body 는 마운트당 여러 번 평가된다.
        var distinctClocks: [LoadClock] {
            builds.map(\.clock).reduce(into: [LoadClock]()) { result, clock in
                if !result.contains(where: { $0 === clock }) { result.append(clock) }
            }
        }
    }

    private struct Probe: View {
        let token: Int
        let recorder: Recorder

        var body: some View {
            MountClock { clock in
                recorder.builds.append((clock, clock.startedAt))
                return Color.clear.frame(width: 10, height: 10)
            }
            .id(token)
        }
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    func testEachMountGetsItsOwnClockStartedFromScratch() throws {
        let recorder = Recorder()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let host = UIHostingController(rootView: Probe(token: 0, recorder: recorder))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        window.layoutIfNeeded()
        defer { window.isHidden = true }
        pump(0.1)

        let first = try XCTUnwrap(recorder.distinctClocks.first)
        XCTAssertTrue(recorder.builds.allSatisfy { $0.startedAt == nil },
                      "빌드 시점엔 기산점이 없어야 한다 — 동기 메모리 히트는 0ms 다")
        let firstStart = try XCTUnwrap(first.startedAt, "마운트 뒤에는 기산점이 찍혀야 한다")

        // 리마운트(디코드 박스 변경·뷰포트 재등장과 같은 모양).
        host.rootView = Probe(token: 1, recorder: recorder)
        window.layoutIfNeeded()
        pump(0.1)

        let clocks = recorder.distinctClocks
        XCTAssertEqual(clocks.count, 2, "리마운트가 새 시계를 받지 못했다")
        let second = try XCTUnwrap(clocks.last)
        XCTAssertFalse(second === first, "이전 마운트의 시계를 그대로 쓰면 시간이 누적된다")
        XCTAssertTrue(recorder.builds.allSatisfy { $0.startedAt == nil },
                      "새 마운트도 빌드 시점엔 기산점이 없어야 한다")
        let secondStart = try XCTUnwrap(second.startedAt)
        XCTAssertGreaterThan(secondStart, firstStart, "새 마운트의 기산점이 갱신되지 않았다")
    }
}
