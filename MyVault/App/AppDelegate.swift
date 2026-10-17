import UIKit
import UserNotifications

/// Routes notification taps to the matching Special Day, and hands files opened from
/// outside the app (Files, AirDrop, another app) to the backup import flow.
///
/// Two entry points matter for document opening, and both are required:
///
/// * `application(_:didFinishLaunchingWithOptions:)` — the app was **not running**, so
///   iOS delivers the URL in `launchOptions`. Without reading it here, tapping a
///   `.mvbackup` in Files would launch the app and silently drop the file.
/// * `application(_:open:options:)` — the app was **already running** (foreground or
///   background), so iOS delivers the URL directly.
///
/// Both funnel into `AppState.openBackupDocument(at:)`, which only stages the file.
/// Authentication and the backup password are handled later by the UI, so an incoming
/// document can never bypass the lock screen.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Cold launch from a document. `AppState` is not reachable yet — the SwiftUI
        // scene has not been created — so the URL is held here and collected once the
        // app state exists (see `takePendingLaunchURL`).
        if let url = Self.backupURL(from: launchOptions) {
            launchURL = url
        }
        return true
    }

    /// The app was running (foreground or background) and the user opened a file.
    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        NotificationCenter.default.post(name: .didOpenBackupDocument, object: url)
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

    // MARK: - Document opening

    /// Set on a cold launch that was caused by opening a document. Read once by the
    /// scene so the same file is not opened twice.
    private var launchURL: URL?

    /// Returns and clears the cold-launch URL, if any.
    func takePendingLaunchURL() -> URL? {
        defer { launchURL = nil }
        return launchURL
    }

    /// Extracts a document URL from launch options, ignoring anything that is not a
    /// `.mvbackup` so a stray URL cannot push arbitrary files into the importer.
    ///
    /// A document open at cold launch arrives under the URL launch option
    /// (`UIApplicationLaunchOptionsURLKey`), which Swift exposes only as a raw string.
    private static func backupURL(from launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> URL? {
        let key = UIApplication.LaunchOptionsKey(rawValue: "UIApplicationLaunchOptionsURLKey")
        guard let candidate = launchOptions?[key] as? URL,
              MyVaultBackupType.looksLikeBackup(candidate) else { return nil }
        return candidate
    }
}

extension Notification.Name {
    static let didOpenSpecialDayNotification = Notification.Name("mv.didOpenSpecialDay")
    /// Posted when the system hands the app a file to open while it is already running.
    static let didOpenBackupDocument = Notification.Name("mv.didOpenBackupDocument")
}
