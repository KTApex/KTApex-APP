import UIKit
import UserNotifications

/// Routes notification taps to the matching Special Day so the app can deep-link.
/// Uses UNUserNotificationCenterDelegate (set once here) and forwards the tapped
/// event id to the active AppState via NotificationCenter.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show the banner even when the app is foregrounded.
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo["specialDayID"] as? String {
            NotificationCenter.default.post(name: .didOpenSpecialDayNotification, object: id)
        }
        completionHandler()
    }
}

extension Notification.Name {
    static let didOpenSpecialDayNotification = Notification.Name("mv.didOpenSpecialDay")
}
