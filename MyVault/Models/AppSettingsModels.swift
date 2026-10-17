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
    /// Auto-lock timeout in seconds. `0` means *immediately*; `Self.neverLocks`
    /// means *never*.
    ///
    /// "Never" needs a value that `didBecomeActive` cannot confuse with "immediately".
    /// The previous code treated every value `<= 0` as immediate, so a `0`-based
    /// sentinel would have locked the vault the instant the app came to the foreground
    /// instead of never locking it.
    static let neverLocks = -1

    static var autoLockTimeout: Int { UserDefaults.standard.object(forKey: "mv.autolock") as? Int ?? 60 }
    static func setAutoLock(_ s: Int) { UserDefaults.standard.set(s, forKey: "mv.autolock") }

    /// True when the user has asked MyVault never to lock on its own.
    static var autoLockDisabled: Bool { autoLockTimeout == neverLocks }

    /// Whether "Never" is a safe choice on this device.
    ///
    /// Never is a legitimate convenience setting, but it is only defensible when the
    /// user can still put the vault back into a locked state by other means: biometrics
    /// or a PIN. With neither configured, "Never" would leave encrypted media reachable
    /// with no re-entry path at all, so the option is refused instead of silently
    /// accepted.
    static var neverAutoLockAllowed: Bool {
        biometricEnabled || PINService.shared.isEnabled
    }
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
