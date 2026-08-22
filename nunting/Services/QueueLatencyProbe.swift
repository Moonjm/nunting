import Foundation
import os
import SDWebImage

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
    static let main = QueueLatencyProbe(name: "main",
                                        submit: { DispatchQueue.main.async(execute: $0) })

    /// `SDImageCache` 의 내부 직렬 `ioQueue` — 조회/저장이 한 줄로 서는 그 큐다.
    /// 큐 객체에 직접 접근할 수 없으므로, **그 큐를 타는 가장 싼 공개 API**(디스크
    /// 존재 확인)를 핑으로 쓴다. 34장 분량의 조회·저장이 줄 서 있으면 이 왕복이
    /// 그대로 초 단위로 늘어난다.
    ///
    /// 왜 필요한가: "읽기만 막기" 도 "쓰기만 미루기" 도 각각은 효과가 없었고
    /// (show p90 5,021ms / 5,011ms), 둘을 동시에 없앴을 때만 383ms 로 무너졌다.
    /// 개별 동작이 아니라 **직렬 큐가 한 줄로 처리하는 구조**가 병목이라는 해석인데,
    /// 그 해석 자체가 맞는지 재본 적이 없다. 여섯 번 틀린 뒤라 이번엔 먼저 잰다.
    static let imageCacheIO = QueueLatencyProbe(
        name: "io",
        submit: { block in
            SDImageCache.shared.containsImage(forKey: "__nunting.ioProbe__",
                                              cacheType: .disk) { _ in block() }
        })

    /// 백그라운드 전역 큐 — **디코드 블록이 실행 순서를 기다리는지** 본다.
    /// 오퍼레이션의 전송 후 구간이 p50 252ms / p90 2,074ms 인데 그 안의 디코드는
    /// 11ms 뿐이다. 남은 시간이 스레드 풀 포화 때문이라면 여기서 같이 잡힌다.
    /// QoS 는 SDWebImage 디코드 블록이 도는 결과 비슷하게 `.utility`.
    static let background = QueueLatencyProbe(
        name: "bg",
        submit: { DispatchQueue.global(qos: .utility).async(execute: $0) })

    /// 핑을 어떻게 던질지. 큐 객체를 직접 못 잡는 대상(`ioQueue`)도 재려고
    /// 큐가 아니라 **제출 방식**을 받는다.
    private let submit: @Sendable (@escaping @Sendable () -> Void) -> Void
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
    init(name: String,
         submit: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
         interval: TimeInterval = 0.25,
         thresholdMs: Int = 100,
         heartbeat: TimeInterval = 5,
         onLag: (@Sendable (Int) -> Void)? = nil) {
        self.submit = submit
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
            submit { [weak self] in
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
