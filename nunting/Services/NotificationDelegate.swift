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
        Task { @MainActor in
            DetailOverlayController.shared.present(url: url, title: title)
        }
    }
}
