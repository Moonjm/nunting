import Foundation
import QuartzCore

/// 서버 `/me/metrics?kind=hitch` 로 보내는 프레임 히치 리포트. 키는 Go admin 뷰와 합의.
nonisolated struct FrameHitchReportDTO: Encodable, Sendable {
    let ts: Int              // epoch seconds (기록 종료 시점)
    let label: String        // 어떤 인터랙션인지 (예: "backdrag")
    let context: String      // 상관 분석용 부가 정보 (예: "comments 210/400")
    let durationMs: Int      // 기록 구간 길이
    let frameCount: Int
    let droppedFrames: Int
    let worstFrameMs: Double
    let expectedFrameMs: Double
    let worstFrames: [Double] // 최악 프레임 간격 상위 몇 개(ms)
    let sessionDrags: Int     // 실행 후 이 라벨로 기록한 총 횟수 — 리포트가 안 온 드래그와의 비율
    let worstFrameAtMs: Int   // 최악 프레임이 구간 시작 몇 ms 지점이었나
    let markLabel: String     // 구간을 둘로 가르는 지점의 이름(예: "release")
    let markAtMs: Int         // 그 지점의 시각(구간 시작 기준). 0 이면 마크 없음
    let dropsBeforeMark: Int
    let dropsAfterMark: Int
}

/// 프레임 간격 표본에서 통계를 뽑는 순수 계산부.
///
/// `CADisplayLink` 는 프레임마다 "이번 프레임이 화면에 나갈 예정 시각"
/// (`targetTimestamp`)을 함께 주므로, 기대 간격을 하드코딩하지 않아도 된다 —
/// ProMotion 은 8.3ms 와 16.7ms 사이를 오가고 저전력 모드에선 더 길어진다.
nonisolated struct FrameHitchStats: Sendable, Equatable {
    let frameCount: Int
    let droppedFrames: Int
    let worstFrameMs: Double
    let expectedFrameMs: Double
    let worstFrames: [Double]
    /// 최악 프레임이 구간 시작 기준 몇 초 지점이었나.
    let worstFrameAt: Double
    /// `mark` 이전/이후로 나눈 드랍 수 — 마크가 없으면 전부 before 로 센다.
    let dropsBeforeMark: Int
    let dropsAfterMark: Int

    /// 기대 간격 대비 이 배수를 넘긴 프레임만 "늦었다"고 본다. 1.5 인 이유:
    /// 정확히 한 프레임을 놓치면 간격이 2배가 되고, 측정 잡음(디스플레이 링크
    /// 콜백 자체의 지터)은 그보다 훨씬 작다. 1.0 바로 위로 잡으면 정상 프레임도
    /// 절반쯤 걸린다.
    static let lateThreshold = 1.5

    /// 상위 몇 개의 최악 간격을 리포트에 싣는지.
    static let worstSampleCount = 5

    /// `samples` 는 (구간 시작 기준 시각, 실제 간격, 기대 간격) 의 초 단위 값.
    /// `markAt` 은 구간을 둘로 가르는 시각(예: 스냅샷을 걷은 순간) — nil 이면
    /// 전부 이전 구간으로 센다.
    static func make(
        from samples: [(at: Double, actual: Double, expected: Double)],
        markAt: Double? = nil
    ) -> FrameHitchStats {
        guard !samples.isEmpty else {
            return FrameHitchStats(
                frameCount: 0, droppedFrames: 0, worstFrameMs: 0,
                expectedFrameMs: 0, worstFrames: [],
                worstFrameAt: 0, dropsBeforeMark: 0, dropsAfterMark: 0
            )
        }

        var dropped = 0
        var before = 0
        var after = 0
        for sample in samples where sample.expected > 0 {
            let ratio = sample.actual / sample.expected
            guard ratio > lateThreshold else { continue }
            // 간격이 기대의 3.2배면 그 사이 프레임 2장이 화면에 못 나갔다.
            let missed = max(0, Int(ratio.rounded()) - 1)
            dropped += missed
            // 늦은 프레임의 지연은 그 프레임이 *끝난* 시점까지 쌓인 것이므로,
            // 구간 판정도 끝 시각(`at`)으로 한다.
            if let markAt, sample.at > markAt { after += missed } else { before += missed }
        }

        let worst = samples.max { $0.actual < $1.actual }
        let intervalsMs = samples.map { $0.actual * 1000 }.sorted(by: >)
        let expected = samples.map(\.expected).reduce(0, +) / Double(samples.count) * 1000

        return FrameHitchStats(
            frameCount: samples.count,
            droppedFrames: dropped,
            worstFrameMs: intervalsMs.first ?? 0,
            expectedFrameMs: expected,
            worstFrames: Array(intervalsMs.prefix(worstSampleCount)),
            worstFrameAt: worst?.at ?? 0,
            dropsBeforeMark: before,
            dropsAfterMark: after
        )
    }
}

/// 특정 인터랙션 구간의 프레임 간격을 재는 진단 계측기.
///
/// 왜 필요했나: "댓글 많은 글에서 뒤로 스와이프하면 버벅인다" 를 기기 밖에서
/// 확인할 방법이 없었다. HangWatchdog 는 임계가 1.0s 라 프레임 몇 장 빠지는
/// 수준을 못 잡고, MetricKit 은 이 앱 페이로드에 animationMetrics 를 실어주지
/// 않으며, 시뮬레이터 유닛 테스트로 잰 메인스레드 비용은 실체화된 댓글 행
/// 30/150/310 개 모두에서 프레임당 1.1ms 로 평평했다(= CPU 원인이 아님).
/// 남은 후보는 렌더 서버 합성인데 그건 기기에서 프레임 간격을 직접 재야 보인다.
///
/// `CADisplayLink` 는 메인 런루프에 붙으므로 메인 스레드가 막히면 콜백도 늦는다
/// — 즉 여기서 재는 간격은 "메인 스레드 정체 + 커밋 지연" 을 함께 반영한다.
/// 렌더 서버만 늦고 메인은 한가한 경우는 간격이 벌어지지 않을 수 있는데, 그
/// 경우 "프레임은 제때 커밋됐다" 는 것 자체가 원인을 좁히는 증거가 된다.
@MainActor
final class FrameHitchRecorder: NSObject {
    static let shared = FrameHitchRecorder()

    /// 기록 종료 후 이만큼 더 재고 끝낸다 — 손을 뗀 뒤의 스프링 복귀
    /// (`.spring(response: 0.32)`) 와 닫기 슬라이드가 이 구간에 들어온다.
    /// 사용자가 "버벅인다" 고 느끼는 구간은 손가락을 뗀 뒤까지 포함한다.
    static let settleWindow: Duration = .milliseconds(500)

    private var link: CADisplayLink?
    private var samples: [(at: Double, actual: Double, expected: Double)] = []
    private var markLabel = ""
    private var markAt: Double?
    private var lastTimestamp: CFTimeInterval = 0
    private var startedAt: CFTimeInterval = 0
    private var label = ""
    private var context = ""
    private var stopTask: Task<Void, Never>?
    private var dragCounts: [String: Int] = [:]

    private let onReport: @Sendable (FrameHitchReportDTO) -> Void

    /// 업로드 실패는 로그만 — 진단 데이터라 재시도하지 않는다(HangWatchdog 동일).
    init(onReport: @escaping @Sendable (FrameHitchReportDTO) -> Void = { report in
        Task { @MainActor in
            do {
                try await AlertSubscriptionService.shared.reportFrameHitch(report)
            } catch {
                NSLog("[FrameHitchRecorder] report failed: \(error.localizedDescription)")
            }
        }
    }) {
        self.onReport = onReport
        super.init()
    }

    /// 기록 시작. 이미 기록 중이면 그 구간을 이어 쓴다(드래그 도중 재진입 방지).
    func begin(label: String, context: String) {
        stopTask?.cancel()
        stopTask = nil
        guard link == nil else { return }

        self.label = label
        self.context = context
        samples.removeAll(keepingCapacity: true)
        lastTimestamp = 0
        markLabel = ""
        markAt = nil
        startedAt = CACurrentMediaTime()
        dragCounts[label, default: 0] += 1

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // .common: 스크롤/드래그 중에도 콜백이 끊기지 않게(default 모드만 쓰면
        // 트래킹 런루프 모드에서 멈춰 정작 재고 싶은 구간이 통째로 빈다).
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// 손을 뗀 시점에 호출 — 스프링이 정착할 시간까지 더 재고 마무리한다.
    func endAfterSettle() {
        guard link != nil, stopTask == nil else { return }
        stopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleWindow)
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    /// 구간 안의 특정 사건 시각을 기록한다 — 드랍 프레임을 그 앞/뒤로 갈라
    /// "드래그 중"과 "그 뒤(스냅샷 해제·정착)" 중 어디서 걸리는지 본다.
    func mark(_ label: String) {
        guard link != nil, markAt == nil else { return }
        markLabel = label
        markAt = CACurrentMediaTime() - startedAt
    }

    /// 즉시 마무리(구간이 취소된 경우 등).
    func finish() {
        stopTask?.cancel()
        stopTask = nil
        guard let link else { return }
        link.invalidate()
        self.link = nil

        let stats = FrameHitchStats.make(from: samples, markAt: markAt)
        let durationMs = Int((CACurrentMediaTime() - startedAt) * 1000)
        samples.removeAll(keepingCapacity: true)

        // 매끄러운 드래그는 올리지 않는다 — 세션당 수십 번 일어나는 동작이라
        // 전부 올리면 admin 뷰가 정상 기록으로 뒤덮인다. 대신 `sessionDrags` 로
        // "몇 번 중 몇 번이 걸렸는지" 비율을 볼 수 있게 한다.
        guard stats.droppedFrames > 0 else { return }

        onReport(FrameHitchReportDTO(
            ts: Int(Date().timeIntervalSince1970),
            label: label,
            context: context,
            durationMs: durationMs,
            frameCount: stats.frameCount,
            droppedFrames: stats.droppedFrames,
            worstFrameMs: stats.worstFrameMs,
            expectedFrameMs: stats.expectedFrameMs,
            worstFrames: stats.worstFrames,
            sessionDrags: dragCounts[label] ?? 0,
            worstFrameAtMs: Int(stats.worstFrameAt * 1000),
            markLabel: markLabel,
            markAtMs: Int((markAt ?? 0) * 1000),
            dropsBeforeMark: stats.dropsBeforeMark,
            dropsAfterMark: stats.dropsAfterMark
        ))
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        // 첫 틱은 이전 프레임 시각이 없어 간격을 못 만든다.
        guard lastTimestamp > 0 else { return }
        let expected = link.targetTimestamp - link.timestamp
        samples.append((
            at: link.timestamp - startedAt,
            actual: link.timestamp - lastTimestamp,
            expected: expected
        ))
    }
}

/// 진단용 — 지금 상세에 실제로 그려진 댓글 행 수. `FrameHitchRecorder` 가
/// 리포트 `context` 에 실어 "실체화된 행 수 ↔ 히치" 상관을 보게 한다.
/// (`CommentRenderWindow` 로 창이 열린 만큼만 실체화되므로, 같은 글이라도
/// 사용자가 얼마나 읽어 내려갔느냐에 따라 달라진다.)
@MainActor
final class CommentRenderProbe {
    static let shared = CommentRenderProbe()

    private(set) var rendered = 0
    private(set) var total = 0

    func update(rendered: Int, total: Int) {
        self.rendered = rendered
        self.total = total
    }

    var summary: String { "comments \(rendered)/\(total)" }
}
