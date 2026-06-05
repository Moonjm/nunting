import Foundation

/// 하단 바 종 아이콘의 안 읽은 알림 개수. 종이 KeywordListView 밖(하단 바)에
/// 있어 그 바깥에서도 개수를 알아야 하므로 공유 모델로 둔다. 매칭/이력은 전부
/// 서버가 source of truth 라(클라는 푸시를 받을 뿐) alert-history 를 받아 미읽음만
/// 센다 — 1인·수백 행 규모라 별도 count 엔드포인트 없이도 비용이 무시할 만하다.
///
/// 갱신 트리거: 앱 첫 진입(.task), foreground 재진입(scenePhase .active),
/// foreground 푸시 도착(NotificationDelegate.willPresent), 푸시 탭 읽음
/// 처리(didReceive), 알림 시트 닫힘(onDismiss).
@MainActor
@Observable
final class AlertBadge {
    /// alert-history 를 가져오는 의존성. 기본은 서버 호출이지만, 테스트에서
    /// 클로저를 주입해 unread/0건/실패 케이스를 .shared 없이 검증한다.
    typealias HistoryFetch = () async throws -> [AlertHistoryItem]

    static let shared = AlertBadge()

    private let fetch: HistoryFetch

    init(fetch: @escaping HistoryFetch = { try await AlertSubscriptionService.shared.fetchAlertHistory() }) {
        self.fetch = fetch
    }

    /// 안 읽은 알림 수. 하단 바 종 위 빨강 뱃지로 표시(0 이면 숨김).
    var unread: Int = 0

    /// alert-history 를 받아 미읽음 개수로 갱신. 실패하면 직전 값 유지
    /// (네트워크 일시 오류로 뱃지가 깜빡 사라지지 않게).
    func refresh() async {
        guard let history = try? await fetch() else { return }
        unread = history.filter { !$0.read }.count
    }
}
