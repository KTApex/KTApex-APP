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
        // The store lives in the app's own Application Support directory.
        //
        // The target declares an App Group (for the widget's `UserDefaults`), and if
        // SwiftData is left to pick a location itself it can resolve the store into
        // that shared container. On a simulator (or any build where the App Group is
        // not provisioned) that directory does not exist, so opening the store fails
        // and every `@Query`-backed screen stays blank. Pinning the URL keeps the
        // vault database in the app sandbox on every device, and the App Group is
        // used only for the non-sensitive widget summary.
        let storeURL: URL = {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base.appendingPathComponent("MyVault.store")
        }()
        // `cloudKitDatabase: .none` is intentional: MyVault is local-only by design,
        // so the store is never mirrored to iCloud behind the user's back.
        let config = ModelConfiguration(schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
        do { return try ModelContainer(for: schema, configurations: [config]) }
        catch {
            // A corrupt or unreadable store must not brick the app: fall back to an
            // in-memory container so the UI still works, and report it in the log.
            NSLog("MyVault: persistent store unavailable (\\(error)); using in-memory store")
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do { return try ModelContainer(for: schema, configurations: [memory]) }
            catch { fatalError("Could not create ModelContainer: \\(error)") }
        }
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
        // Clear scratch space left by a share, export or restore that was interrupted
        // by a crash or by the system terminating the app.
        ShareService.purgeStaleExports()
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
