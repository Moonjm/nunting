import Foundation

/// structureChanged 파서 실패를 서버로 집계하는 세션 단위 리포터.
///
/// 사이트가 마크업을 개편하면 파서는 감지(`ParserError.structureChanged`)까지는
/// 하지만 신호가 기기 안에서 죽었다 — 사용자에겐 에러 배너, 개발자에겐 무소식.
/// 여기서 (site, phase) 를 `/me/metrics?kind=parser` 로 올려 "조용한 이탈"을
/// "당일 파악"으로 바꾼다. 해석은 서버 admin 뷰 몫.
///
/// - 세션 dedup: 같은 (site, phase) 는 세션당 1회만 전송 — 파손된 보드를
///   스크롤/재시도할 때마다 중복 업로드하지 않는다. detail 문자열은 dedup
///   키에 안 넣는다(같은 파손의 변주일 뿐).
/// - 전송 실패 시 dedup 키를 되돌려 다음 발생 때 재시도한다. 별도 재시도
///   루프는 없다 — 파손은 반복 발생하므로 다음 발생이 곧 재시도 기회다
///   (MetricsReporter 의 no-retry 근거와 동일).
final class ParserFailureTelemetry {
    static let shared = ParserFailureTelemetry()

    /// (site, phase, detail) 전송 시임 — 테스트가 네트워크 없이 기록/실패 주입.
    typealias Sender = (String, String, String) async throws -> Void

    private let sender: Sender
    private var reported: Set<String> = []

    init(sender: @escaping Sender = { site, phase, detail in
        try await AlertSubscriptionService.shared.reportParserFailure(
            site: site, phase: phase, detail: detail)
    }) {
        self.sender = sender
    }

    enum Phase: String {
        case list
        case detail
        /// 본문은 성공했지만 댓글 API/마크업이 깨진 경우 — Etoland 처럼 댓글
        /// 경로가 본문과 독립적으로 파손되는 사이트를 구분해 집계한다.
        case comments
    }

    /// fire-and-forget — 호출부(로더)는 결과를 기다리지 않는다. 반환 Task 는
    /// 테스트가 전송 완료를 결정적으로 기다리는 용도. 세션 내 중복이면 nil.
    @discardableResult
    func report(site: Site, phase: Phase, detail: String) -> Task<Void, Never>? {
        let key = "\(site.rawValue)|\(phase.rawValue)"
        guard reported.insert(key).inserted else { return nil }
        return Task {
            do {
                try await sender(site.rawValue, phase.rawValue, detail)
            } catch {
                NSLog("[ParserFailureTelemetry] upload failed (\(key), \(detail)): \(error.localizedDescription)")
                reported.remove(key)
            }
        }
    }
}
