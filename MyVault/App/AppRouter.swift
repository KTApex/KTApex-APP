import SwiftUI

enum AppTab: Hashable { case home, vault, specialDays, settings }
enum AppRoute: Hashable {
    case albumDetail(String)
    case mediaViewer(String)
    case specialDayDetail(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .home
    @Published var isUnlocked = false
    @Published var onboardingCompleted: Bool = UserDefaults.standard.bool(forKey: "mv.onboardingCompleted")
    @Published var navigationPath = NavigationPath()
    @Published var deepLinkedSpecialDayID: String?

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
        let timeout = AppSettingsStore.autoLockTimeout
        if timeout <= 0 { lock(); return }
        if let t = backgroundedAt, Date().timeIntervalSince(t) >= Double(timeout) { lock() }
        backgroundedAt = nil
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
    /// Locks the vault and clears in-memory decrypted thumbnail caches so no
    /// plaintext image data lingers after the app is backgrounded/locked.
    func lock() {
        isUnlocked = false
        ThumbnailCache.shared.clear()
        backgroundedAt = nil
    }
}
