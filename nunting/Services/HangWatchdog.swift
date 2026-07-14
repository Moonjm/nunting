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
/// 빌드에서만 전달된다 — 이 앱처럼 Xcode 설치로만 쓰는 빌드에는 영원히 안 옴
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
/// 캡처와 리포트의 직렬화: 캡처는 raw 주소 워크(µs 단위)만 하고 즉시 락 안에 커밋,
/// 느린 심볼화(ms 단위)는 리포트 확정 후 백그라운드 태스크에서 한다. 그래도 남는
/// 워크~커밋 사이 틈은 `captureInFlight` 가드로 막는다 — pong 이 그 틈에 도착하면
/// 리포트를 파킹해 뒀다가 캡처 커밋 쪽에서 확정한다. 임계 직후에 끝나는 hang 의
/// 유일한 샘플이 리포트에서 빠지는 레이스 방지.
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

    /// 심볼화 전의 스택 샘플 — 캡처 시점엔 raw 주소만 커밋한다.
    private struct RawSample: Sendable {
        let atMs: Int
        let addresses: [UInt64]
    }

    /// pong 이 확정한 hang 의 메타데이터. 캡처가 진행 중이면 커밋을 기다리며 파킹된다.
    private struct PendingHang: Sendable {
        let ts: Int
        let durationMs: Int
        let label: String
    }

    private struct State {
        var running = false
        var paused = false
        var mainThreadPort: thread_t = 0
        var label = "launch"
        var onReport: @Sendable (HangReportDTO) -> Void
        // 진행 중 ping. nil 이면 다음 틱에 새 ping 을 보낸다.
        var pingSentAt: TimeInterval?
        var samples: [RawSample] = []
        var nextSampleIndex = 0
        var lastTick: TimeInterval = 0
        // 스택 워크~커밋 사이 틈에 pong 이 도착했을 때의 직렬화 (헤더 주석 참조).
        var captureInFlight = false
        var pendingReport: PendingHang?
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
            $0.pendingReport = nil
        }
    }

    /// scenePhase 백그라운드 진입 시 — suspend 를 hang 으로 오인하지 않게 멈춘다.
    func pause() {
        state.withLock {
            $0.paused = true
            $0.pingSentAt = nil
            $0.samples = []
            $0.pendingReport = nil
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
                s.pendingReport = nil
                return .none
            }
            guard let sentAt = s.pingSentAt else {
                // 직전 hang 의 캡처/리포트 확정이 끝나기 전엔 새 ping 을 미룬다
                // (samples 리셋이 파킹된 리포트의 샘플을 지우지 않게).
                guard !s.captureInFlight, s.pendingReport == nil else { return .none }
                s.pingSentAt = now
                s.samples = []
                s.nextSampleIndex = 0
                return .sendPing
            }
            let elapsed = now - sentAt
            if !s.captureInFlight,
               s.nextSampleIndex < sampleOffsets.count,
               elapsed >= sampleOffsets[s.nextSampleIndex] {
                s.nextSampleIndex += 1
                s.captureInFlight = true
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
            // raw 워크만 락 밖에서(µs 단위) — 심볼화는 리포트 확정 후로 미룬다.
            let addresses = ThreadBacktrace.rawAddresses(thread: port)
            let parked: (PendingHang, [RawSample])? = state.withLock { s in
                s.captureInFlight = false
                if !addresses.isEmpty {
                    s.samples.append(RawSample(atMs: atMs, addresses: addresses))
                }
                // 워크 중 메인이 풀려 pong 이 리포트를 파킹해 뒀다면 지금 확정.
                guard let pending = s.pendingReport else { return nil }
                s.pendingReport = nil
                let samples = s.samples
                s.samples = []
                return (pending, samples)
            }
            if let (pending, samples) = parked { emit(pending, samples) }
        }
    }

    // MARK: - Main thread

    /// 메인 큐가 ping 에 응답하는 순간 — 임계를 넘겼었다면 hang 이 방금 끝난 것이다.
    private func pong() {
        let now = ProcessInfo.processInfo.systemUptime
        let ready: (PendingHang, [RawSample])? = state.withLock { s in
            guard let sentAt = s.pingSentAt, s.running, !s.paused else {
                s.pingSentAt = nil
                return nil
            }
            s.pingSentAt = nil
            let elapsed = now - sentAt
            guard elapsed >= threshold else {
                s.samples = []
                s.nextSampleIndex = 0
                return nil
            }
            let pending = PendingHang(
                ts: Int(Date().timeIntervalSince1970),
                durationMs: Int(elapsed * 1000),
                label: s.label
            )
            if s.captureInFlight {
                // 캡처가 워크~커밋 사이 — 커밋 쪽(tick)에서 확정하게 파킹.
                s.pendingReport = pending
                return nil
            }
            let samples = s.samples
            s.samples = []
            return (pending, samples)
        }
        if let (pending, samples) = ready { emit(pending, samples) }
    }

    // MARK: - Report

    /// 심볼화(ms 단위) + 업로드 핸들러 호출 — 메인/워치독 어느 쪽 hot path 에도
    /// 얹지 않게 유틸리티 태스크에서 한다.
    private func emit(_ pending: PendingHang, _ samples: [RawSample]) {
        let handler = state.withLock { $0.onReport }
        Task.detached(priority: .utility) {
            let report = HangReportDTO(
                ts: pending.ts,
                durationMs: pending.durationMs,
                label: pending.label,
                samples: samples.map {
                    HangSampleDTO(atMs: $0.atMs, frames: ThreadBacktrace.symbolicate($0.addresses))
                }
            )
            handler(report)
        }
    }
}
