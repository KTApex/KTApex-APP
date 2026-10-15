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
    /// Biometrics are only skippable while a PIN exists as the fallback. Without
    /// one, honouring "off" would leave the owner locked out of their own vault.
    static var biometricUnlockAllowed: Bool { biometricEnabled || !PINService.shared.isEnabled }
}
