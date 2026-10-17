import Foundation
import SwiftData

@Model
final class AppSettings {
    var id: String = "singleton"
    var biometricEnabled: Bool = true
    var pinEnabled: Bool = false
    var autoLockSeconds: Int = 60
    var defaultReminderHour: Int = 9
    var defaultReminderMinute: Int = 0
    init() {}
}

@Model
final class BackupMetadata {
    var id: String = UUID().uuidString
    var lastBackupAt: Date?
    var isEnabled: Bool = false
    var encryptedItemCount: Int = 0
    init() {}
}

enum AppSettingsStore {
    static var autoLockTimeout: Int { UserDefaults.standard.object(forKey: "mv.autolock") as? Int ?? 60 }
    static func setAutoLock(_ s: Int) { UserDefaults.standard.set(s, forKey: "mv.autolock") }
    static var biometricEnabled: Bool { UserDefaults.standard.object(forKey: "mv.bio") as? Bool ?? true }
    static func setBiometricEnabled(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: "mv.bio") }

    /// When on, reminder notifications never contain an event title.
    ///
    /// A lock-screen banner is readable without unlocking the phone, so an event title
    /// like "Mum's birthday" leaks private information about a vault app's contents to
    /// anyone who glances at the device. This is a preference, not a secret: it lives in
    /// UserDefaults because losing it costs nothing and it must be readable before the
    /// vault is unlocked (notifications are scheduled while the app may be locked).
    /// Defaults to on, because the privacy-preserving choice is the safe default.
    static var notificationPrivacyMode: Bool {
        UserDefaults.standard.object(forKey: "mv.notifPrivacy") as? Bool ?? true
    }
    static func setNotificationPrivacyMode(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "mv.notifPrivacy")
    }

    /// Biometrics are only skippable while a PIN exists as the fallback. Without
    /// one, honouring "off" would leave the owner locked out of their own vault.
    static var biometricUnlockAllowed: Bool { biometricEnabled || !PINService.shared.isEnabled }
}
