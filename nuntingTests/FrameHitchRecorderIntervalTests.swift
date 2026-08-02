import XCTest
@testable import nunting

/// 히치 구간의 경계 계약 — 제스처 하나가 구간 하나다.
///
/// 회귀: 정착 창(500ms) 안에 다음 드래그가 시작되면 앞 구간이 아직 살아 있어
/// 두 제스처가 한 표본 집합으로 합쳐졌다. 개별로는 멀쩡한 두 드래그가 합쳐져
/// 리포트 임계를 넘길 수 있고, 횟수는 한 번만 세지며, duration·context 는
/// 어느 쪽도 설명하지 못한다.
@MainActor
final class FrameHitchRecorderIntervalTests: XCTestCase {

    func testEachGestureCountsAsItsOwnInterval() {
        let recorder = FrameHitchRecorder(onReport: { _ in })

        recorder.begin(label: "backdrag", context: "first")
        XCTAssertTrue(recorder.isRecordingForTesting)
        XCTAssertEqual(recorder.sessionDragsForTesting(label: "backdrag"), 1)

        // 앞 구간이 아직 안 끝난 채로 다음 드래그가 시작된다.
        recorder.begin(label: "backdrag", context: "second")

        XCTAssertTrue(recorder.isRecordingForTesting, "새 구간이 시작되지 않았다")
        XCTAssertEqual(recorder.sessionDragsForTesting(label: "backdrag"), 2,
                       "두 제스처가 한 구간으로 합쳐졌다")
        recorder.finish()
    }

    func testFinishStopsRecording() {
        let recorder = FrameHitchRecorder(onReport: { _ in })
        recorder.begin(label: "backdrag", context: "only")
        recorder.finish()
        XCTAssertFalse(recorder.isRecordingForTesting)
    }

    // MARK: - 기대 간격 짝짓기 (가변 주사율)

    /// 콜백 시퀀스를 `FrameIntervalSampler` 에 그대로 흘려 표본을 만든다 —
    /// CADisplayLink 가 주는 값과 같은 모양(콜백 시각, 그 콜백의 targetTimestamp).
    ///
    /// 시각은 `base` 만큼 밀어서 넣는다. 0 에서 시작하면 첫 콜백 뒤에도
    /// `lastTimestamp` 가 0 이라 두 번째 표본까지 버려져(기기에서는 부팅 이후
    /// 시각이라 절대 0 이 아니다) 정작 보려던 전환 구간이 표본에서 빠진다 —
    /// 처음 쓴 상승 전환 테스트가 그래서 공회전했다.
    private func samples(
        base: Double = 1_000,
        _ callbacks: [(timestamp: Double, target: Double)]
    ) -> [(at: Double, actual: Double, expected: Double)] {
        var sampler = FrameIntervalSampler()
        return callbacks.compactMap {
            sampler.sample(timestamp: base + $0.timestamp,
                           targetTimestamp: base + $0.target,
                           startedAt: base)
        }
    }

    /// **회귀: 주사율 전환을 드랍으로 세면 안 된다.**
    ///
    /// `targetTimestamp - timestamp` 는 그 콜백 **다음** 간격의 기대치다. 이번에
    /// 잰 실제 간격(직전 콜백부터 지금까지)과 짝지으면, 60→120Hz 전환에서 정상
    /// 16.7ms 프레임이 8.3ms 기대와 비교돼 비율 2.0 → 드랍 1장으로 잡힌다.
    /// ProMotion 기기는 스크롤이 멈추면 주사율을 내리므로 드래그 구간마다 이
    /// 전환이 실제로 일어난다 — 회귀 경보로 쓰는 수치가 상시 부풀 수 있다.
    func testCadenceChangeUpDoesNotFakeADroppedFrame() {
        let f60 = 1.0 / 60, f120 = 1.0 / 120
        // 60Hz 로 두 프레임 → 그 다음부터 120Hz. 실제 간격은 내내 정상이다.
        let stats = FrameHitchStats.make(from: samples([
            (timestamp: 0, target: f60),
            (timestamp: f60, target: f60 + f120),          // 여기서 주사율이 바뀐다
            (timestamp: f60 + f120, target: f60 + 2 * f120),
            (timestamp: f60 + 2 * f120, target: f60 + 3 * f120),
        ]))

        XCTAssertEqual(stats.droppedFrames, 0, "주사율이 올라간 걸 드랍으로 셌다")
    }

    /// 반대 전환(120→60Hz)에서는 진짜 드랍이 가려진다 — 실제로 한 장 빠진
    /// 간격이 큰 기대치와 비교돼 정상으로 통과한다.
    func testCadenceChangeDownStillCatchesARealDrop() {
        let f60 = 1.0 / 60, f120 = 1.0 / 120
        // 120Hz 로 돌다가 한 장 빠진다(8.3ms 자리에 16.7ms). 늦게 온 그 콜백이
        // 마침 "다음은 60Hz" 를 예고하므로, 자기 값과 짝지으면 비율 1.0 이 되어
        // 진짜 드랍이 묻힌다. 직전 콜백이 예고한 8.3ms 와 짝지어야 잡힌다.
        let stats = FrameHitchStats.make(from: samples([
            (timestamp: 0, target: f120),
            (timestamp: f120, target: 2 * f120),
            (timestamp: 2 * f120, target: 3 * f120),                  // 아직 120Hz
            (timestamp: 2 * f120 + f60, target: 2 * f120 + 2 * f60),  // 한 장 빠지고 60Hz 로
        ]))

        XCTAssertEqual(stats.droppedFrames, 1, "주사율이 내려가는 구간의 진짜 드랍을 놓쳤다")
    }
}
