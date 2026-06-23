import Foundation

/// 서버 `/me/footprint` 로 보내는 샘플 한 점. 키는 Go `db.FootprintSample` 과 합의.
struct FootprintSampleDTO: Encodable {
    let ts: Int      // epoch seconds
    let label: String
    let mb: Int      // phys_footprint
    let avail: Int   // 한도까지 남은 여유
    let live: Int    // malloc size_in_use(살아있는 힙)
    let alloc: Int   // malloc size_allocated(OS 예약). alloc-live=단편화 진단
}

/// 메모리 footprint 를 이벤트 태깅 + 변화량 기반으로 샘플링해 서버로 배치 전송한다.
///
/// 목적: 앱이 사용 중 OOM(~678MB) 으로 죽는 지점을 찾기 — "어느 화면/동작에서 메모리가
/// 치솟나", "뒤로 갔는데 안 풀리나"를 서버 admin 뷰의 타임라인으로 본다.
///
/// 설계:
/// - 이벤트(`record`)는 항상 한 점 남긴다(보드 전환·글 열기·scenePhase 등 의미 있는 순간).
/// - 샘플러는 `sampleIntervalSec` 마다 깨어나되, footprint 가 직전 기록 대비
///   `changeThresholdMB` 이상 움직였을 때만 기록 → 평상시(flat)엔 거의 안 쌓여
///   서버/DB 부담이 작다.
/// - 버퍼가 `flushThreshold` 차거나 백그라운드/메모리경고 시 묶어서 POST. 전송 실패는
///   진단 데이터라 재시도 없이 로그만.
@MainActor
final class FootprintLogger {
    static let shared = FootprintLogger()

    private let service: AlertSubscriptionService
    private var buffer: [FootprintSampleDTO] = []
    private var lastSampledMB = 0
    private var samplerTask: Task<Void, Never>?

    private let changeThresholdMB = 25
    private let flushThreshold = 60
    private let sampleIntervalNanos: UInt64 = 3 * 1_000_000_000

    /// 선제 flush — footprint 가 이 값을 넘으면 OS 메모리경고(실측상 ~900MB 에서야
    /// 옴)를 기다리지 말고 in-memory 캐시를 미리 비운다. 과거 frontmost OOM kill 이
    /// 678MB 에서 났으므로 그 아래에서 발동해 ratchet 바닥을 낮춘다. (라이브 뷰가
    /// 잡은 메모리는 못 비우므로 근본 해결은 아니고, 캐시분만 선제 회수.)
    private let proactiveFlushMB = 650
    /// 연속 flush 폭주(=재디코드 CPU 낭비) 방지 쿨다운.
    private let flushCooldownSec = 20
    private var lastProactiveFlushTs = 0

    private init() {
        // .shared 를 init 본문에서 잡는다 — default-arg 로 두면 nonisolated
        // 컨텍스트에서 평가돼 main-actor 경고가 난다.
        self.service = .shared
    }

    /// 앱 시작 시 1회. 기준점 한 점 + 샘플러 루프 가동.
    func start() {
        record("launch")
        guard samplerTask == nil else { return }
        samplerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.sampleIntervalNanos ?? 3_000_000_000)
                self?.sampleIfChanged()
            }
        }
    }

    /// 이벤트 기록 — 라벨 있는 한 점을 항상 남긴다.
    func record(_ label: String) {
        append(label: label, mb: MemoryFootprint.currentMB())
        if buffer.count >= flushThreshold { flush() }
    }

    /// 백그라운드 진입: 마지막 한 점 남기고 즉시 flush(샘플러는 suspend 됨).
    func onBackground() {
        record("scenePhase:background")
        flush()
    }

    /// 버퍼를 서버로 보내고 비운다.
    func flush() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        Task {
            do {
                try await service.reportFootprint(batch)
            } catch {
                NSLog("[FootprintLogger] flush failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private

    /// 샘플러 틱 — 선제 flush 판정 후, footprint 가 직전 기록 대비 threshold 이상
    /// 움직였을 때만 기록.
    private func sampleIfChanged() {
        let mb = MemoryFootprint.currentMB()
        maybeProactiveFlush(mb)
        guard abs(mb - lastSampledMB) >= changeThresholdMB else { return }
        append(label: "Δ", mb: mb)
        if buffer.count >= flushThreshold { flush() }
    }

    /// footprint 가 임계를 넘고 쿨다운이 지났으면 in-memory 캐시를 선제 회수한다.
    /// 발동 시점을 타임라인(`proactive-flush@<mb>`)에 남겨 효과(직후 Δ 하락)를 본다.
    private func maybeProactiveFlush(_ mb: Int) {
        guard mb >= proactiveFlushMB else { return }
        let now = Int(Date().timeIntervalSince1970)
        guard now - lastProactiveFlushTs >= flushCooldownSec else { return }
        lastProactiveFlushTs = now
        record("proactive-flush@\(mb)")
        MemoryPressureResponder.shared.respond()
    }

    private func append(label: String, mb: Int) {
        lastSampledMB = mb
        let malloc = MemoryFootprint.mallocMB()
        buffer.append(FootprintSampleDTO(
            ts: Int(Date().timeIntervalSince1970),
            label: label,
            mb: mb,
            avail: MemoryFootprint.availableMB(),
            live: malloc.live,
            alloc: malloc.alloc
        ))
    }
}
