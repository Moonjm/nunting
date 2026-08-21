import XCTest
import os
@testable import nunting

/// `MainQueueLatencyProbe` — 메인 큐가 얼마나 밀려 있는지 잰다.
///
/// 왜: 오퍼레이션 수명의 94%가 "전송 후" 구간이고(p50 1,545ms) 그 안에서 하는 실제
/// 일은 디코드 11ms 뿐이다. 남은 1.5초는 완료 처리가 메인 큐에서 차례를 기다린
/// 시간이라는 가설이고, 이 프로브가 그걸 직접 재서 확정한다.
///
/// `HangWatchdog` 과 같은 결이지만 잡는 게 다르다 — 워치독은 1초 이상 **한 번** 멈추는
/// 것을 보고(오늘 0건), 이건 짧은 작업이 줄줄이 밀려 큐가 정체되는 것을 본다.
final class MainQueueLatencyProbeTests: XCTestCase {

    /// 메인을 막으면 그만큼의 지연이 기록돼야 한다.
    func testRecordsLatencyWhileMainIsBusy() {
        let recorded = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let exp = expectation(description: "lag recorded")
        // 0.3초 블록이면 쌓인 핑이 여러 개 한꺼번에 풀린다 — 초과 이행이 정상이다.
        exp.assertForOverFulfill = false
        let probe = MainQueueLatencyProbe(
            interval: 0.02,
            thresholdMs: 30,
            onLag: { ms in
                recorded.withLock { $0.append(ms) }
                exp.fulfill()
            }
        )
        probe.start()
        defer { probe.stop() }

        // 메인을 0.3초 막는다 — 그동안 쌓인 핑이 풀릴 때 지연으로 잡힌다.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        Thread.sleep(forTimeInterval: 0.3)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        wait(for: [exp], timeout: 2)
        let worst = recorded.withLock { $0.max() ?? 0 }
        XCTAssertGreaterThanOrEqual(worst, 100, "0.3초 블록이 지연으로 안 잡혔다: \(worst)ms")
    }

    /// 한산할 때는 아무것도 안 남긴다 — 임계 미만은 버린다. 평상시에도 기록하면
    /// 배치가 프로브 이벤트로 뒤덮인다(이벤트 예산이 이미 이미지 쪽에 쓰이고 있다).
    func testStaysSilentWhenMainIsIdle() {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let probe = MainQueueLatencyProbe(interval: 0.02, thresholdMs: 200,
                                          onLag: { _ in count.withLock { $0 += 1 } })
        probe.start()
        defer { probe.stop() }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        XCTAssertEqual(count.withLock { $0 }, 0)
    }

    /// `stop()` 뒤에는 더 기록하지 않는다(세션 종료 후 유령 이벤트 방지).
    func testStopEndsProbing() {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let probe = MainQueueLatencyProbe(interval: 0.02, thresholdMs: 1,
                                          onLag: { _ in count.withLock { $0 += 1 } })
        probe.start()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        probe.stop()
        let afterStop = count.withLock { $0 }

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(count.withLock { $0 }, afterStop, "stop 후에도 기록됐다")
    }
}
