import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        // 매 launch마다 권한 상태 확인 후 이미 .authorized면 다시 register.
        // iOS 업데이트/container 마이그레이션 시 deviceToken이 회전되는데
        // `didRegister`는 register 호출 후에만 fire되므로 이걸 안 하면 stale
        // token이 서버에 남아 푸시 silent 미수신. PUT은 idempotent라 같은 토큰
        // 재전송은 무해.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }

        // Memory pressure response. iOS sends `didReceiveMemoryWarning` via
        // both the delegate method below AND the matching notification —
        // route both through `MemoryPressureResponder.shared.respond()`
        // (idempotent flush). The responder owns the SDImageCache /
        // URLCache flush so the wiring stays testable.
        MemoryPressureResponder.shared.installDefaultHandlers()
        MemoryPressureResponder.shared.start()

        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        MemoryPressureResponder.shared.respond()
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

    /// 권한 거부 / network 등 다양한 사유. APNs 410 self-heal이 서버 측에서
    /// 정리하므로 여기서는 logging만.
    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[AppDelegate] didFailToRegister: \(error)")
    }
}
