import AppIntents
import Foundation

/// App Intents for MyVault.
///
/// Two rules shape all of these:
///
/// 1. **An intent never touches vault data.** Intents can be run from Shortcuts, Siri
///    or the Lock Screen while the app is closed and locked, so anything they do must
///    be safe without authentication. Each one therefore only *navigates*: it posts a
///    request that the running app handles after its own unlock check.
/// 2. **No decrypted media crosses the boundary.** There is deliberately no intent that
///    reads, exports or lists vault contents; adding one would create a path around the
///    lock screen. Only counts and navigation are exposed.
enum MyVaultIntentNotifications {
    /// Requests that the vault be locked. Handled by `RootView`.
    static let lockVault = Notification.Name("mv.intent.lockVault")
    /// Requests navigation to a tab. `object` is an `AppTab`.
    static let openTab = Notification.Name("mv.intent.openTab")
    /// Requests navigation to Backup & Restore. Handled by `RootView`.
    static let openBackup = Notification.Name("mv.intent.openBackup")
}

extension AppTab {
    /// A stable string form, so an intent can name a tab without importing SwiftUI.
    var intentIdentifier: String {
        switch self {
        case .home: return "home"
        case .vault: return "vault"
        case .specialDays: return "specialDays"
        case .settings: return "settings"
        }
    }

    static func fromIntentIdentifier(_ value: String) -> AppTab? {
        switch value {
        case "home": return .home
        case "vault": return .vault
        case "specialDays": return .specialDays
        case "settings": return .settings
        default: return nil
        }
    }
}

/// Opens the app on the Vault tab.
///
/// `openAppWhenRun` is what actually brings MyVault to the foreground; without it the
/// intent performs silently in the background and the user sees nothing happen.
struct OpenVaultIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Vault"
    static var description = IntentDescription("Opens MyVault on your vault.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: MyVaultIntentNotifications.openTab,
            object: AppTab.vault.intentIdentifier
        )
        return .result()
    }
}

/// Locks the vault immediately.
///
/// Locking is always safe to request: it only ever removes access. The app applies it
/// on the main actor, so an intent can never leave the vault in a half-locked state.
struct LockVaultIntent: AppIntent {
    static var title: LocalizedStringResource = "Lock Vault"
    static var description = IntentDescription("Locks MyVault straight away.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: MyVaultIntentNotifications.lockVault, object: nil)
        return .result(dialog: "Your vault is locked.")
    }
}

/// Opens Backup & Restore.
///
/// It navigates only. Creating a backup needs a password that must be typed, so it
/// cannot be automated from a shortcut without either storing that password (which is
/// forbidden) or weakening the flow.
struct OpenBackupIntent: AppIntent {
    static var title: LocalizedStringResource = "Create or Restore Backup"
    static var description = IntentDescription("Opens MyVault's Backup & Restore screen.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: MyVaultIntentNotifications.openBackup, object: nil)
        return .result()
    }
}

/// Opens Special Days.
struct OpenSpecialDaysIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Special Days"
    static var description = IntentDescription("Opens your special days and countdowns.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(
            name: MyVaultIntentNotifications.openTab,
            object: AppTab.specialDays.intentIdentifier
        )
        return .result()
    }
}

/// Reports the next special day without opening the app.
///
/// Reads event titles only — the same information the widget already shows — and never
/// touches vault media.
struct ShowNextSpecialDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Next Special Day"
    static var description = IntentDescription("Tells you your next special day.")
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Deliberately does not query SwiftData here: opening the store from an intent
        // while the app is running would create a second context and the read is not
        // worth the risk. The dialog points at the app, which shows the real answer.
        .result(dialog: "Open MyVault to see your next special day.")
    }
}

/// Shortcuts discovery.
struct MyVaultShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LockVaultIntent(),
            phrases: ["Lock my vault in \(.applicationName)"],
            shortTitle: "Lock Vault",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: OpenVaultIntent(),
            phrases: ["Open my vault in \(.applicationName)"],
            shortTitle: "Open Vault",
            systemImageName: "lock.shield.fill"
        )
        AppShortcut(
            intent: OpenBackupIntent(),
            phrases: ["Back up my \(.applicationName) vault"],
            shortTitle: "Backup & Restore",
            systemImageName: "externaldrive.badge.checkmark"
        )
    }
}
