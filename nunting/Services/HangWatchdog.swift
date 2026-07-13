import Foundation
import os

/// 서버 `/me/metrics?kind=hang` 으로 보내는 hang 리포트. 키는 Go admin 뷰와 합의.
nonisolated struct HangSampleDTO: Encodable, Sendable {
    let atMs: Int        // ping 기준 캡처 시점
    let frames: [String] // 심볼화된 메인 스레드 스택
}

nonisolated struct HangReportDTO: Encodable, Sendable {
    let ts: Int          // epoch seconds (hang 종료 시점)
    let durationMs: Int
    let label: String    // 직전 사용자 동작 브레드크럼 (FootprintLogger 라벨 재사용)
    let samples: [HangSampleDTO]
}

/// 메인 스레드 hang 을 직접 감지·기록하는 워치독.
///
/// 배경: MetricKit 의 hang 콜스택(`MXHangDiagnostic`)은 TestFlight/App Store 배포
/// 빌드에서만 전달된다 — 이 앱처럼 Xcode 설치로만 쓰는 빌드에는 영원히 안 온다
/// (서버 로그 전 기간에서 kind=diagnostic 수신 0건으로 실증). 일일 집계 히스토그램은
/// 오지만 건수·시간 분포뿐이라 "어디서 막혔나"를 못 본다. 그래서 FootprintLogger 와
/// 같은 직접 수집 방식으로: 전용 스레드가 메인 큐에 ping 을 던지고, pong 이 임계
/// 이상 늦으면 hang 진행 중에 메인 스레드 스택을 다중 샘플(임계·2×·4× 시점)로 캡처,
/// 메인이 풀리는 순간 리포트를 올린다. MetricKit 과 달리 즉시 도착하고 개발 빌드
/// 심볼이 살아 있다.
///
/// 오탐 방어 두 겹:
/// - scenePhase 백그라운드 진입 시 `pause()` — suspend 된 메인 큐를 hang 으로 오인 방지.
/// - 루프 갭 자가 점검 — 워치독 스레드 자신도 오래 못 돈 시간(프로세스 전체 suspend,
///   디버거 일시정지)은 진행 중 ping 을 버린다. 진짜 hang 은 메인만 멈추고 워치독은
///   계속 돌므로 구분된다.
///
/// 격리: 앱 기본 격리가 MainActor 라 타입을 `nonisolated` 로 열고, 가변 상태는 전부
/// `OSAllocatedUnfairLock` 안에 둔다(워치독 스레드·메인 스레드 양쪽에서 접근).
nonisolated final class HangWatchdog: Sendable {

    static let shared = HangWatchdog(onReport: { report in
        // 업로드는 진단 데이터 — 실패해도 재시도 없이 로그만 (FootprintLogger 와 동일).
        Task { @MainActor in
            do {
                try await AlertSubscriptionService.shared.reportHang(report)
            } catch {
                NSLog("[HangWatchdog] report failed: \(error.localizedDescription)")
            }
        }
    })

    private struct State {
        var running = false
        var paused = false
        var mainThreadPort: thread_t = 0
        var label = "launch"
        var onReport: @Sendable (HangReportDTO) -> Void
        // 진행 중 ping. nil 이면 다음 틱에 새 ping 을 보낸다.
        var pingSentAt: TimeInterval?
        var samples: [HangSampleDTO] = []
        var nextSampleIndex = 0
        var lastTick: TimeInterval = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let pingInterval: TimeInterval
    private let threshold: TimeInterval
    /// ping 기준 스택 캡처 시점 — 임계, 2×, 4×. 긴 hang 은 구간별 원인이 갈리므로
    /// (예: 1s 시점 디코드 → 3s 시점 레이아웃) 최대 3장을 찍는다.
    private let sampleOffsets: [TimeInterval]

    init(
        pingInterval: TimeInterval = 0.1,
        threshold: TimeInterval = 1.0,
        onReport: @escaping @Sendable (HangReportDTO) -> Void
    ) {
        self.pingInterval = pingInterval
        self.threshold = threshold
        self.sampleOffsets = [threshold, threshold * 2, threshold * 4]
        self.state = OSAllocatedUnfairLock(initialState: State(onReport: onReport))
    }

    /// 앱 시작 시 1회, 메인 스레드에서 호출(메인 mach port 를 여기서 잡는다).
    @MainActor
    func start() {
        let port = pthread_mach_thread_np(pthread_self())
        let alreadyRunning = state.withLock { s in
            let was = s.running
            s.running = true
            s.mainThreadPort = port
            s.lastTick = ProcessInfo.processInfo.systemUptime
            return was
        }
        guard !alreadyRunning else { return }

        let thread = Thread { [weak self] in
            while let self, self.state.withLock({ $0.running }) {
                Thread.sleep(forTimeInterval: self.pingInterval)
                self.tick()
            }
        }
        thread.name = "HangWatchdog"
        // 메인이 막혀 시스템이 바쁜 순간에도 워치독 틱은 제때 돌아야 캡처 시점이 정확하다.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        state.withLock {
            $0.running = false
            $0.pingSentAt = nil
        }
    }

    /// scenePhase 백그라운드 진입 시 — suspend 를 hang 으로 오인하지 않게 멈춘다.
    func pause() {
        state.withLock {
            $0.paused = true
            $0.pingSentAt = nil
            $0.samples = []
        }
    }

    func resume() {
        state.withLock {
            $0.paused = false
            $0.lastTick = ProcessInfo.processInfo.systemUptime
        }
    }

    /// 직전 사용자 동작 브레드크럼 — 리포트의 label 로 실린다.
    func noteEvent(_ label: String) {
        state.withLock { $0.label = label }
    }

    /// 테스트 전용 — 리포트 핸들러 교체.
    func onReportForTesting(_ handler: @escaping @Sendable (HangReportDTO) -> Void) {
        state.withLock { $0.onReport = handler }
    }

    // MARK: - Watchdog thread

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        enum Action {
            case none
            case sendPing
            case capture(port: thread_t, atMs: Int)
        }
        let action: Action = state.withLock { s in
            guard s.running, !s.paused else { return .none }
            // 워치독 자신이 오래 못 돌았다면(프로세스 suspend/디버거 정지) 이번 ping 은
            // 무효 — 경과시간이 hang 이 아니라 suspend 시간이다.
            let gap = now - s.lastTick
            s.lastTick = now
            if gap > max(1.0, pingInterval * 10) {
                s.pingSentAt = nil
                s.samples = []
                return .none
            }
            guard let sentAt = s.pingSentAt else {
                s.pingSentAt = now
                s.samples = []
                s.nextSampleIndex = 0
                return .sendPing
            }
            let elapsed = now - sentAt
            if s.nextSampleIndex < sampleOffsets.count, elapsed >= sampleOffsets[s.nextSampleIndex] {
                s.nextSampleIndex += 1
                return .capture(port: s.mainThreadPort, atMs: Int(elapsed * 1000))
            }
            return .none
        }

        switch action {
        case .none:
            return
        case .sendPing:
            DispatchQueue.main.async { [weak self] in self?.pong() }
        case .capture(let port, let atMs):
            // 캡처(suspend+워크+심볼화)는 락 밖에서 — pong 이 락에서 대기하지 않게.
            let frames = ThreadBacktrace.capture(thread: port)
            guard !frames.isEmpty else { return }
            state.withLock { $0.samples.append(HangSampleDTO(atMs: atMs, frames: frames)) }
        }
    }

    // MARK: - Main thread

    /// 메인 큐가 ping 에 응답하는 순간 — 임계를 넘겼었다면 hang 이 방금 끝난 것이다.
    private func pong() {
        let now = ProcessInfo.processInfo.systemUptime
        let report: HangReportDTO? = state.withLock { s in
            defer {
                s.pingSentAt = nil
                s.samples = []
                s.nextSampleIndex = 0
            }
            guard let sentAt = s.pingSentAt, s.running, !s.paused else { return nil }
            let elapsed = now - sentAt
            guard elapsed >= threshold else { return nil }
            return HangReportDTO(
                ts: Int(Date().timeIntervalSince1970),
                durationMs: Int(elapsed * 1000),
                label: s.label,
                samples: s.samples
            )
        }
        guard let report else { return }
        state.withLock { $0.onReport }(report)
    }
}
