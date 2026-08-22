import Foundation
import os

/// 메인 큐가 얼마나 밀려 있는지 재는 프로브.
///
/// 배경: 이미지 오퍼레이션 수명의 94%가 "전송 후" 구간이었다(p50 1,545ms). 그 안에서
/// 하는 실제 일은 디코드 11ms 뿐이라, 나머지는 완료 처리가 **메인 큐에서 차례를
/// 기다린 시간**이라는 가설이 남았다. 그 가설을 직접 재서 확정하려고 만든다.
///
/// `HangWatchdog` 과 결은 같지만 잡는 게 다르다 — 워치독은 1초 이상 **한 번** 멈추는
/// 것을 보고(이 증상에서는 0건이었다), 이건 짧은 작업이 줄줄이 밀려 큐가 정체되는
/// 것을 본다. 그래서 임계가 낮고 주기가 짧다.
///
/// 비용: 주기마다 빈 블록 하나를 메인에 넣는 게 전부다. 임계 미만은 버려서 한산할
/// 때는 이벤트가 안 쌓인다.
///
/// 격리: 전용 스레드에서 돌고 상태는 락 안에 둔다(`HangWatchdog` 과 같은 패턴).
nonisolated final class QueueLatencyProbe: Sendable {
    /// 메인 큐 — 뷰 반영이 밀리는지 본다.
    static let main = QueueLatencyProbe(queue: .main, name: "main")

    /// 백그라운드 전역 큐 — **디코드 블록이 실행 순서를 기다리는지** 본다.
    /// 오퍼레이션의 전송 후 구간이 p50 252ms / p90 2,074ms 인데 그 안의 디코드는
    /// 11ms 뿐이다. 남은 시간이 스레드 풀 포화 때문이라면 여기서 같이 잡힌다.
    /// QoS 는 SDWebImage 디코드 블록이 도는 결과 비슷하게 `.utility`.
    static let background = QueueLatencyProbe(
        queue: DispatchQueue.global(qos: .utility), name: "bg")

    private let queue: DispatchQueue
    private let name: String

    private let interval: TimeInterval
    private let thresholdMs: Int
    private let heartbeat: TimeInterval
    private let running = OSAllocatedUnfairLock(initialState: false)
    /// 하트비트 창 안에서 관측한 최대 지연. 창이 끝나면 **0 이어도** 한 건 남긴다 —
    /// 이벤트가 0건이면 "정체가 없었다" 와 "프로브가 안 돌았다" 를 구분할 수 없고,
    /// 실제로 그 모호함 때문에 한 세션을 날렸다.
    private let windowMax = OSAllocatedUnfairLock(initialState: 0)

    /// - Parameters:
    ///   - onLag: 테스트 주입점. 프로덕션은 기본값(계측 채널)을 쓴다.
    init(queue: DispatchQueue = .main,
         name: String = "main",
         interval: TimeInterval = 0.25,
         thresholdMs: Int = 100,
         heartbeat: TimeInterval = 5,
         onLag: (@Sendable (Int) -> Void)? = nil) {
        self.queue = queue
        self.name = name
        self.interval = interval
        self.thresholdMs = thresholdMs
        self.heartbeat = heartbeat
        self.injectedOnLag = onLag
    }

    private let injectedOnLag: (@Sendable (Int) -> Void)?

    private func onLag(_ ms: Int) {
        if let injectedOnLag { injectedOnLag(ms); return }
        let event = MediaLoadEventDTO.queueLatency(queue: name, kind: "lag", ms: ms)
        Task { @MainActor in MediaLoadTelemetry.shared.record(event) }
    }

    func start() {
        running.withLock { $0 = true }
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "nunting.queueLatencyProbe.\(name)"
        thread.qualityOfService = .utility
        thread.start()
    }

    func stop() { running.withLock { $0 = false } }

    private func loop() {
        var lastHeartbeat = Date()
        while running.withLock({ $0 }) {
            let sentAt = Date()
            queue.async { [weak self] in
                guard let self, self.running.withLock({ $0 }) else { return }
                let delayMs = Int(Date().timeIntervalSince(sentAt) * 1000)
                self.windowMax.withLock { $0 = max($0, delayMs) }
                // 임계 초과는 즉시 남긴다(정체 순간의 크기).
                guard delayMs >= self.thresholdMs else { return }
                self.onLag(delayMs)
            }
            if Date().timeIntervalSince(lastHeartbeat) >= heartbeat {
                lastHeartbeat = Date()
                let peak = windowMax.withLock { value -> Int in
                    defer { value = 0 }
                    return value
                }
                onHeartbeat(peak)
            }
            Thread.sleep(forTimeInterval: interval)
        }
    }

    /// 창당 한 건. 값이 0 이어도 남기는 게 요점이다.
    private func onHeartbeat(_ peakMs: Int) {
        let event = MediaLoadEventDTO.queueLatency(queue: name, kind: "peak", ms: peakMs)
        Task { @MainActor in MediaLoadTelemetry.shared.record(event) }
    }
}
