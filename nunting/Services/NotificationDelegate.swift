import UserNotifications
import UIKit

/// UNUserNotificationCenter delegate.
/// `willPresent`: foreground 시에도 시스템 배너 + 사운드 — 커스텀 in-app 토스트 안 만듦.
/// `didReceive`: payload `url` 추출해 detail overlay 진입.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard let urlStr = userInfo["url"] as? String, let url = URL(string: urlStr) else { return }
        let title = response.notification.request.content.body

        // 푸시 탭 = 글 열기 → 읽음 처리. payload 의 alert_id 로 서버 read_at set.
        // (JSON number 라 NSNumber 로 들어옴. 0/누락이면 무시 — 이력 기록 실패 케이스.)
        if let alertID = (userInfo["alert_id"] as? NSNumber)?.intValue, alertID > 0 {
            Task { try? await AlertSubscriptionService.shared.markAlertRead(id: alertID) }
        }

        Task { @MainActor in
            DetailOverlayController.shared.present(url: url, title: title)
        }
    }
}
