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
        backgroundedAt = Date()
        let timeout = AppSettingsStore.autoLockTimeout
        if timeout <= 0 { lock(); return }
    }
    func didBecomeActive() {
        guard onboardingCompleted else { return }
        let timeout = AppSettingsStore.autoLockTimeout
        if !isUnlocked { return }
        if timeout <= 0 { lock(); return }
        if let t = backgroundedAt, Date().timeIntervalSince(t) >= Double(timeout) { lock() }
        if !isUnlocked { Task { await authenticateIfNeeded() } }
    }
    func authenticateIfNeeded() async {
        if isUnlocked { return }
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
