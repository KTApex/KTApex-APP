import Foundation
import SwiftUI

enum AppTab: Hashable { case home, vault, specialDays, settings }
enum AppRoute: Hashable {
    case albumDetail(String)
    case mediaViewer(String)
    case specialDayDetail(String)
}

/// A backup the system asked MyVault to open from outside the app.
///
/// `url` is a copy inside MyVault's own scratch space, not the raw Files URL: the
/// security scope is released as soon as the copy exists, so nothing downstream has
/// to hold a provider's permission open. `id` is regenerated per request so opening
/// the same file twice is still two distinct, observable events.
struct PendingBackupOpen: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var displayName: String
    /// Directory holding `url`; released once the request is consumed or dismissed.
    var directory: URL

    static func == (lhs: PendingBackupOpen, rhs: PendingBackupOpen) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var isUnlocked = false
    @Published var onboardingCompleted: Bool = UserDefaults.standard.bool(forKey: "mv.onboardingCompleted")
    @Published var navigationPath = NavigationPath()
    @Published var deepLinkedSpecialDayID: String?
    /// A backup the user asked to open from Files. `RootView` observes this and
    /// presents the import screen once the app is unlocked, so a document open never
    /// skips authentication.
    @Published var pendingBackupOpen: PendingBackupOpen?
    /// Message shown when a document open could not be prepared. Cleared once shown.
    @Published var documentOpenError: String?

    private let authService = AuthenticationService.shared
    private var backgroundedAt: Date?

    /// UI-testing hook. Only active when XCTest launches the app with
    /// `--uitesting` (an argument the production binary never receives), so it
    /// does not weaken real authentication. It lets UI tests reach the tab
    /// interface deterministically on a simulator without enrolled biometrics.
    private let uiTesting = ProcessInfo.processInfo.arguments.contains("--uitesting")

    init() {
        if uiTesting {
            // Skip onboarding + lock so UI tests can exercise navigation.
            onboardingCompleted = true
            isUnlocked = true
        }
    }

    func didEnterBackground() {
        // Drop decrypted thumbnails immediately, but defer the lock decision to the
        // next activation: locking here would present the lock screen (and its
        // biometric prompt) behind the app-switcher cover, where the prompt cannot
        // succeed and the user would come back to a lock screen that never asked.
        ThumbnailCache.shared.clear()
        backgroundedAt = Date()
    }
    func didBecomeActive() {
        guard onboardingCompleted else { return }
        guard isUnlocked else {
            // Already locked. Re-prompt only when returning from the background — on
            // a cold launch LockScreenView prompts from its own onAppear, and asking
            // twice would launch two competing biometric evaluations.
            if backgroundedAt != nil {
                backgroundedAt = nil
                Task { await authenticateIfNeeded() }
            }
            return
        }

        // "Never" is honoured only while it is still a safe choice. If the user removed
        // both biometrics and the PIN — for example by disabling the PIN later — a
        // stored "Never" would leave the vault reachable with no way back to a locked
        // state, so it falls back to a one-minute lock instead of being obeyed blindly.
        guard Self.shouldHonourNeverAutoLock else {
            if let t = backgroundedAt, Date().timeIntervalSince(t) >= 60 { lock() }
            backgroundedAt = nil
            return
        }

        let timeout = AppSettingsStore.autoLockTimeout
        if timeout == AppSettingsStore.neverLocks {
            // Explicitly configured: no timeout. The vault still locks on relaunch,
            // on manual Lock Now, and when the app is terminated with the vault key
            // cleared, so this is a convenience choice rather than an open door.
            backgroundedAt = nil
            return
        }
        if timeout <= 0 { lock(); return }
        if let t = backgroundedAt, Date().timeIntervalSince(t) >= Double(timeout) { lock() }
        backgroundedAt = nil
    }

    /// Whether a configured "Never" may actually be applied.
    ///
    /// Kept as a computed property rather than inlined so the rule is stated once and
    /// can be asserted by a test.
    static var shouldHonourNeverAutoLock: Bool {
        AppSettingsStore.neverAutoLockAllowed
    }
    func authenticateIfNeeded() async {
        if isUnlocked { return }
        // When the user has turned biometrics off (with a PIN as the fallback),
        // unlocking is owned by the lock screen's PIN field.
        guard AppSettingsStore.biometricUnlockAllowed else { return }
        do {
            let ok = try await authService.authenticate(reason: "Unlock MyVault")
            isUnlocked = ok
        } catch { isUnlocked = false }
    }
    func completeOnboarding() {
        onboardingCompleted = true
        UserDefaults.standard.set(true, forKey: "mv.onboardingCompleted")
        Task { await authenticateIfNeeded() }
    }
    func openSpecialDay(id: String) {
        deepLinkedSpecialDayID = id
        selectedTab = .specialDays
    }

    /// Handles a backup the system asked MyVault to open (Files, AirDrop, another app).
    ///
    /// The URL is copied into MyVault's scratch space here, on the main actor, and the
    /// security scope released immediately — see `BackupFileImporter`. Copying rather
    /// than holding the scope means the rest of the flow (password, decrypt, restore)
    /// cannot be interrupted by a provider going away mid-restore.
    ///
    /// Nothing is decrypted and no password is asked for until `isUnlocked` is true:
    /// the request is parked on `pendingBackupOpen` and `RootView` presents it after
    /// authentication. A locked vault therefore never processes a document.
    func openBackupDocument(at url: URL) {
        do {
            let staged = try BackupFileImporter.stageCopy(of: url)
            pendingBackupOpen = PendingBackupOpen(
                url: staged.url,
                displayName: staged.originalName,
                directory: staged.directory
            )
        } catch {
            // Reported through the same channel as an in-app import failure, so the
            // user is told what happened instead of the tap appearing to do nothing.
            pendingBackupOpen = nil
            documentOpenError = error.localizedDescription
        }
    }

    /// Clears the request and removes its scratch copy. Called when the import screen
    /// is dismissed for any reason, so no backup lingers in temporary storage.
    func clearPendingBackupOpen() {
        if let pending = pendingBackupOpen { SecureScratch.removeDirectory(pending.directory) }
        pendingBackupOpen = nil
    }
    /// Locks the vault and clears in-memory decrypted thumbnail caches so no
    /// plaintext image data lingers after the app is backgrounded/locked.
    func lock() {
        isUnlocked = false
        ThumbnailCache.shared.clear()
        backgroundedAt = nil
    }
}
