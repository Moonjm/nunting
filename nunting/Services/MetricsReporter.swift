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
final class MetricsReporter: NSObject, MXMetricManagerSubscriber {
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
        Task {
            do {
                try await service.reportMetricPayload(json, kind: kind)
            } catch {
                NSLog("[MetricsReporter] upload \(kind) failed: \(error.localizedDescription)")
            }
        }
    }
}
