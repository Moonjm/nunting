import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }

    /// APNs 등록 성공 — deviceToken을 hex로 변환해 서버에 PUT.
    /// 같은 토큰을 매번 PUT해도 서버는 idempotent UPDATE.
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task {
            do {
                try await AlertSubscriptionService.shared.registerPushToken(deviceToken)
            } catch {
                print("[AppDelegate] registerPushToken error: \(error)")
            }
        }
    }

    /// 권한 거부 / network 등 다양한 사유. 토큰 못 받았으니 서버에 null PUT.
    /// 다음에 사용자가 설정에서 켜고 앱 재시작하면 didRegisterForRemoteNotifications가
    /// 다시 호출되어 토큰 PUT.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] didFailToRegister: \(error)")
    }
}
