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

    /// 등간격 프레임 표본 — `at` 은 구간 시작 기준 누적 시각.
    private func evenSamples(count: Int, interval: Double) -> [(at: Double, actual: Double, expected: Double)] {
        (0..<count).map { i in
            (at: Double(i + 1) * interval, actual: interval, expected: interval)
        }
    }

    func testSmoothRunHasNoDroppedFrames() {
        let samples = evenSamples(count: 60, interval: promotion)
        let stats = FrameHitchStats.make(from: samples)

        XCTAssertEqual(stats.frameCount, 60)
        XCTAssertEqual(stats.droppedFrames, 0)
        XCTAssertEqual(stats.expectedFrameMs, 1000 / 120, accuracy: 0.01)
    }

    /// 디스플레이 링크 콜백 자체의 지터(수 % 흔들림)를 드랍으로 세면 안 된다.
    func testJitterIsNotCountedAsDropped() {
        var samples = evenSamples(count: 60, interval: promotion)
        for i in samples.indices {
            let jitter: Double = 1 + Double(i % 5) * 0.06
            samples[i] = (at: samples[i].at, actual: promotion * jitter, expected: promotion)
        }
        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 0)
    }

    /// 간격이 기대의 2배면 프레임 1장이 화면에 못 나갔다.
    func testDoubledIntervalCountsAsOneDroppedFrame() {
        var samples = evenSamples(count: 10, interval: sixty)
        samples[5] = (at: samples[5].at, actual: sixty * 2, expected: sixty)

        let stats = FrameHitchStats.make(from: samples)
        XCTAssertEqual(stats.droppedFrames, 1)
        XCTAssertEqual(stats.worstFrameMs, sixty * 2 * 1000, accuracy: 0.01)
    }

    /// 크게 걸린 한 프레임은 그만큼 여러 장을 삼킨다 — 5배면 4장.
    func testLongStallCountsEveryMissedFrame() {
        var samples = evenSamples(count: 10, interval: sixty)
        samples[3] = (at: samples[3].at, actual: sixty * 5, expected: sixty)

        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 4)
    }

    /// 여러 번 걸리면 합산된다.
    func testDroppedFramesAccumulate() {
        var samples = evenSamples(count: 30, interval: promotion)
        samples[5] = (at: samples[5].at, actual: promotion * 3, expected: promotion)   // 2장
        samples[20] = (at: samples[20].at, actual: promotion * 2, expected: promotion) // 1장

        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 3)
    }

    /// 기대 간격은 프레임마다 달라진다(ProMotion 은 8.3~16.7ms 를 오간다).
    /// 하드코딩한 60Hz 기준으로 재면 120Hz 구간의 정상 프레임이 전부 드랍으로
    /// 잡히므로, 판정은 그 프레임이 알려준 기대값으로 해야 한다.
    func testExpectedIntervalIsPerFrameNotHardcoded() {
        let samples = evenSamples(count: 20, interval: sixty)
        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 0)
    }

    /// 최악 프레임 목록은 내림차순 상위 N개.
    func testWorstFramesAreTopDescending() {
        var samples = evenSamples(count: 20, interval: sixty)
        samples[1] = (at: samples[1].at, actual: 0.100, expected: sixty)
        samples[7] = (at: samples[7].at, actual: 0.050, expected: sixty)
        samples[9] = (at: samples[9].at, actual: 0.030, expected: sixty)

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

    /// 드랍을 마크 앞/뒤로 가른다 — "드래그 중"과 "그 뒤(스냅샷 해제·정착)"
    /// 중 어디서 걸리는지가 다음 수를 가르는 유일한 축이다.
    func testDropsSplitAroundTheMark() {
        var samples = evenSamples(count: 40, interval: sixty)
        samples[5] = (at: samples[5].at, actual: sixty * 3, expected: sixty)   // 마크 전 2장
        samples[30] = (at: samples[30].at, actual: sixty * 4, expected: sixty) // 마크 후 3장
        let markAt = samples[20].at

        let stats = FrameHitchStats.make(from: samples, markAt: markAt)
        XCTAssertEqual(stats.droppedFrames, 5)
        XCTAssertEqual(stats.dropsBeforeMark, 2)
        XCTAssertEqual(stats.dropsAfterMark, 3)
    }

    /// 마크가 없으면(구간이 마크 전에 끝남) 전부 앞 구간으로 센다.
    func testWithoutMarkEverythingCountsAsBefore() {
        var samples = evenSamples(count: 10, interval: sixty)
        samples[4] = (at: samples[4].at, actual: sixty * 3, expected: sixty)

        let stats = FrameHitchStats.make(from: samples)
        XCTAssertEqual(stats.dropsBeforeMark, 2)
        XCTAssertEqual(stats.dropsAfterMark, 0)
    }

    /// 최악 프레임의 시각도 함께 남긴다 — 시작 직후(캡처)인지 끝(교체)인지.
    func testWorstFrameTimestampIsReported() {
        var samples = evenSamples(count: 30, interval: sixty)
        samples[25] = (at: samples[25].at, actual: 0.2, expected: sixty)

        let stats = FrameHitchStats.make(from: samples)
        XCTAssertEqual(stats.worstFrameAt, samples[25].at, accuracy: 0.001)
    }

    /// 기대 간격이 0 인 표본(디스플레이 링크가 targetTimestamp 를 못 준 경우)은
    /// 나눗셈이 폭주하지 않게 건너뛴다.
    func testZeroExpectedIntervalIsIgnored() {
        let samples = [(at: 0.5, actual: 0.5, expected: 0.0),
                       (at: 0.5 + sixty, actual: sixty, expected: sixty)]
        XCTAssertEqual(FrameHitchStats.make(from: samples).droppedFrames, 0)
    }

    /// 그 무효 표본은 **기대 간격 평균에서도** 빠져야 한다. 안 그러면 0 이
    /// 섞여 기대값이 실제보다 작게 나오고, admin 에 찍히는 "기대 16ms" 가
    /// 왜곡돼 드랍 판정 기준을 잘못 읽게 된다.
    func testZeroExpectedIntervalIsExcludedFromTheAverage() {
        var samples = evenSamples(count: 10, interval: sixty)
        samples[3] = (at: samples[3].at, actual: sixty, expected: 0)

        let stats = FrameHitchStats.make(from: samples)
        XCTAssertEqual(stats.expectedFrameMs, 1000 / 60, accuracy: 0.01,
                       "무효 표본이 기대 간격 평균을 끌어내렸다")
    }
}

/// 히치 리포트의 발화 기준 — 원인을 잡은 뒤에는 **회귀 경보**로만 남는다.
/// 정상 범위(드래그당 1~6장 드랍)까지 올라오면 admin 뷰가 정상 기록으로
/// 뒤덮여 정작 회귀가 묻힌다.
@MainActor
final class FrameHitchReportThresholdTests: XCTestCase {
    func testThresholdSitsAboveTheHealthyRange() {
        // 계측된 정상 최대치(6장)보다 위, 회귀로 본 값(10장 이상)보다 아래.
        XCTAssertGreaterThan(FrameHitchRecorder.reportThreshold, 6)
        XCTAssertLessThanOrEqual(FrameHitchRecorder.reportThreshold, 10)
    }
}
