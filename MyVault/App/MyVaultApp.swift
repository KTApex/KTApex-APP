import SwiftUI
import SwiftData
import UserNotifications

@main
struct MyVaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var themeManager = ThemeManager()
    @Environment(\.scenePhase) private var scenePhase

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([VaultAlbum.self, VaultMedia.self, SpecialDay.self, ReminderConfiguration.self, AppSettings.self, BackupMetadata.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do { return try ModelContainer(for: schema, configurations: [config]) }
        catch { fatalError("Could not create ModelContainer: \(error)") }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(themeManager)
                .preferredColorScheme(themeManager.colorScheme)
                .tint(themeManager.accentColorValue)
                .onAppear { configure() }
                .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
        }
        .modelContainer(sharedModelContainer)
    }

    private func configure() {
        NotificationService.shared.requestAuthorizationIfNeeded()
        Task { await KeychainService.shared.ensureVaultKeyExists() }
        Task { @MainActor in
            let events = (try? sharedModelContainer.mainContext.fetch(FetchDescriptor<SpecialDay>())) ?? []
            WidgetSummaryService.refresh(events: events)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            PrivacyShield.shared.showShield()
            appState.didEnterBackground()
        case .active:
            PrivacyShield.shared.hideShield()
            appState.didBecomeActive()
        default: break
        }
    }
}
