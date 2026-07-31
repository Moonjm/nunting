import XCTest
@testable import nunting

/// 프레임 히치 통계(`FrameHitchStats`)의 계약.
///
/// 이 숫자가 백드래그 버벅임의 유일한 증거가 되므로, 오탐(정상 프레임을
/// 드랍으로 세기)과 미탐(진짜 드랍을 놓치기) 양쪽이 다 위험하다.
final class FrameHitchStatsTests: XCTestCase {

    /// 120Hz 기준 한 프레임(초).
    private let promotion = 1.0 / 120.0
    /// 60Hz 기준 한 프레임(초).
    private let sixty = 1.0 / 60.0

    func testSmoothRunHasNoDroppedFrames() {
        let samples = Array(repeating: (actual: promotion, expected: promotion), count: 60)
        let stats = FrameHitchStats.make(from: samples)

        XCTAssertEqual(stats.frameCount, 60)
        XCTAssertEqual(stats.droppedFrames, 0)
        XCTAssertEqual(stats.expectedFrameMs, 1000 / 120, accuracy: 0.01)
    }

    /// 디스플레이 링크 콜백 자체의 지터(수 % 흔들림)를 드랍으로 세면 안 된다.
    func testJitterIsNotCountedAsDropped() {
        let samples = (0..<60).map { i in
            (actual: promotion * (1 + Double(i % 5) * 0.06), expected: promotion)
        }
        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 0)
    }

    /// 간격이 기대의 2배면 프레임 1장이 화면에 못 나갔다.
    func testDoubledIntervalCountsAsOneDroppedFrame() {
        var samples = Array(repeating: (actual: sixty, expected: sixty), count: 10)
        samples[5] = (actual: sixty * 2, expected: sixty)

        let stats = FrameHitchStats.make(from: samples)
        XCTAssertEqual(stats.droppedFrames, 1)
        XCTAssertEqual(stats.worstFrameMs, sixty * 2 * 1000, accuracy: 0.01)
    }

    /// 크게 걸린 한 프레임은 그만큼 여러 장을 삼킨다 — 5배면 4장.
    func testLongStallCountsEveryMissedFrame() {
        var samples = Array(repeating: (actual: sixty, expected: sixty), count: 10)
        samples[3] = (actual: sixty * 5, expected: sixty)

        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 4)
    }

    /// 여러 번 걸리면 합산된다.
    func testDroppedFramesAccumulate() {
        var samples = Array(repeating: (actual: promotion, expected: promotion), count: 30)
        samples[5] = (actual: promotion * 3, expected: promotion)   // 2장
        samples[20] = (actual: promotion * 2, expected: promotion)  // 1장

        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 3)
    }

    /// 기대 간격은 프레임마다 달라진다(ProMotion 은 8.3~16.7ms 를 오간다).
    /// 하드코딩한 60Hz 기준으로 재면 120Hz 구간의 정상 프레임이 전부 드랍으로
    /// 잡히므로, 판정은 그 프레임이 알려준 기대값으로 해야 한다.
    func testExpectedIntervalIsPerFrameNotHardcoded() {
        let samples = Array(repeating: (actual: sixty, expected: sixty), count: 20)
        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 0)
    }

    /// 최악 프레임 목록은 내림차순 상위 N개.
    func testWorstFramesAreTopDescending() {
        var samples = Array(repeating: (actual: sixty, expected: sixty), count: 20)
        samples[1] = (actual: 0.100, expected: sixty)
        samples[7] = (actual: 0.050, expected: sixty)
        samples[9] = (actual: 0.030, expected: sixty)

        let worst = FrameHitchStats.make(from: samples).worstFrames
        XCTAssertEqual(worst.count, FrameHitchStats.worstSampleCount)
        XCTAssertEqual(worst[0], 100, accuracy: 0.01)
        XCTAssertEqual(worst[1], 50, accuracy: 0.01)
        XCTAssertEqual(worst[2], 30, accuracy: 0.01)
        XCTAssertEqual(worst, worst.sorted(by: >))
    }

    /// 표본이 없으면(구간이 너무 짧아 틱이 한 번뿐) 0 으로 떨어져야 한다 —
    /// 리포트 조건이 droppedFrames > 0 이라 빈 리포트가 올라가지 않는다.
    func testEmptySamplesProduceZeroStats() {
        let stats = FrameHitchStats.make(from: [])
        XCTAssertEqual(stats.frameCount, 0)
        XCTAssertEqual(stats.droppedFrames, 0)
        XCTAssertEqual(stats.worstFrameMs, 0)
        XCTAssertTrue(stats.worstFrames.isEmpty)
    }

    /// 기대 간격이 0 인 표본(디스플레이 링크가 targetTimestamp 를 못 준 경우)은
    /// 나눗셈이 폭주하지 않게 건너뛴다.
    func testZeroExpectedIntervalIsIgnored() {
        let samples = [(actual: 0.5, expected: 0.0), (actual: sixty, expected: sixty)]
        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 0)
    }
}
