import Foundation
import MetricKit

/// MetricKit payload 를 받아 서버(`/me/metrics`)로 올리는 구독자.
///
/// 앱이 "그냥 꺼지는" 원인(특히 사용 중 foreground OOM jetsam kill)은 일반 크래시
/// 로그를 남기지 않아 추측만 가능했다. MetricKit 은 OS 가 집계한 종료 사유 카운트
/// (`MXMetricPayload.applicationExitMetric`)와 크래시 콜스택(`MXDiagnosticPayload`)을
/// 하루 1회가량 백그라운드 큐로 전달한다. 여기서는 각 payload 의 `jsonRepresentation()`
/// 을 가공 없이 서버에 POST 하고, 해석/요약은 서버 admin 뷰가 한다.
///
/// 전송 실패해도 재시도하지 않는다 — MetricKit 카운트는 누적이라 다음 전달 때 같은
/// 정보가 다시 오고, 콜백 스레드를 붙잡지 않는 게 낫다.
///
/// `nonisolated` 필수: 이 앱은 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 라
/// 명시 안 하면 클래스가 `@MainActor` 로 추론된다. 그런데 `MXMetricManager` 는
/// `didReceive(_:)` 를 **백그라운드 큐**에서 부른다 — `@MainActor` 로 격리된 콜백을
/// OS 가 백그라운드 스레드에서 때리면 executor 격리 위반으로 콜백이 발화되지 않아
/// payload 가 조용히 유실된다(Swift 6 전환 후 metric 수집이 끊긴 실제 원인).
/// UI 상태 없는 순수 포워더라 nonisolated 가 맞다.
nonisolated final class MetricsReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsReporter()

    private let service: AlertSubscriptionService

    private init(service: AlertSubscriptionService = .shared) {
        self.service = service
        super.init()
    }

    /// 앱 시작 시 1회 호출. `MXMetricManager` 는 subscriber 를 weak 으로 잡으므로
    /// `shared` 싱글톤으로 수명을 보장해야 콜백이 끊기지 않는다.
    func start() {
        MXMetricManager.shared.add(self)
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            upload(payload.jsonRepresentation(), kind: "metric")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            upload(payload.jsonRepresentation(), kind: "diagnostic")
        }
    }

    private func upload(_ json: Data, kind: String) {
        guard !json.isEmpty else { return }
        // service 만 로컬 캡처 — nonisolated 콜백 스레드에서 self 를 Task 로
        // 넘기지 않게. reportMetricPayload 는 async 라 알아서 서비스 격리로 hop.
        let service = self.service
        Task {
            do {
                try await service.reportMetricPayload(json, kind: kind)
            } catch {
                NSLog("[MetricsReporter] upload \(kind) failed: \(error.localizedDescription)")
            }
        }
    }
}
