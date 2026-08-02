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
}
