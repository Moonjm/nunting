import Foundation

/// 하단 바 종 아이콘의 안 읽은 알림 개수. 종이 KeywordListView 밖(하단 바)에
/// 있어 그 바깥에서도 개수를 알아야 하므로 공유 모델로 둔다. 매칭/이력은 전부
/// 서버가 source of truth 라(클라는 푸시를 받을 뿐) alert-history 를 받아 미읽음만
/// 센다 — 1인·수백 행 규모라 별도 count 엔드포인트 없이도 비용이 무시할 만하다.
///
/// 갱신 트리거: 앱 첫 진입(.task), foreground 재진입(scenePhase .active),
/// foreground 푸시 도착(willPresent), 푸시 탭 읽음 처리(didReceive),
/// 알림 시트 닫힘(onDismiss).
@MainActor
@Observable
final class AlertBadge {
    static let shared = AlertBadge()
    private init() {}

    /// 안 읽은 알림 수. 하단 바 종 위 빨강 뱃지로 표시(0 이면 숨김).
    var unread: Int = 0

    /// 서버 alert-history 를 받아 미읽음 개수로 갱신. 실패하면 직전 값 유지
    /// (네트워크 일시 오류로 뱃지가 깜빡 사라지지 않게).
    func refresh() async {
        guard let history = try? await AlertSubscriptionService.shared.fetchAlertHistory() else { return }
        unread = history.filter { !$0.read }.count
    }
}
