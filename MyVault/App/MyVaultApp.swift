import SwiftUI
import SwiftData
import UserNotifications

@main
struct MyVaultApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var themeManager = ThemeManager.shared
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
                // A file opened while the app is running (foreground or background) is
                // delivered here. This is the modern SwiftUI entry point and coexists
                // with the AppDelegate method: whichever the system uses, both end up
                // at `appState.openBackupDocument(at:)`.
                .onOpenURL { url in
                    // Accepted by content, not by name. A backup that passed through a
                    // chat app or a provider can arrive without its extension, and
                    // `PortableBackupService.inspect` validates the magic bytes and
                    // version before anything else happens — so dropping the file here
                    // on the extension alone would refuse a perfectly good backup while
                    // still being safe against non-backups.
                    appState.openBackupDocument(at: url)
                }
                // The AppDelegate method is still required, because when the app is not
                // running iOS delivers the URL before SwiftUI exists. It posts through
                // NotificationCenter; this picks that up once the scene is alive.
                .onReceive(NotificationCenter.default.publisher(for: .didOpenBackupDocument)) { note in
                    guard let url = note.object as? URL else { return }
                    appState.openBackupDocument(at: url)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                    guard appState.isUnlocked, AppSettingsStore.lockOnScreenCapture else { return }
                    PINService.shared.recordSecurityNote("Screenshot detected — vault auto-locked")
                    appState.lock()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                    guard UIScreen.main.isCaptured else {
                        if scenePhase == .active { PrivacyShield.shared.hideShield() }
                        return
                    }
                    guard AppSettingsStore.lockOnScreenCapture else { return }
                    PrivacyShield.shared.showShield()
                    if appState.isUnlocked {
                        PINService.shared.recordSecurityNote("Screen recording detected — vault auto-locked")
                        appState.lock()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                    guard appState.isUnlocked,
                          AppSettingsStore.panicFaceDownLock,
                          UIDevice.current.orientation == .faceDown else { return }
                    Haptics.tap()
                    appState.lock()
                }
        }
        .modelContainer(sharedModelContainer)
    }

    private func configure() {
        // Clear scratch space left by a share, export or restore that was interrupted
        // by a crash or by the system terminating the app.
        ShareService.purgeStaleExports()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationService.shared.requestAuthorizationIfNeeded()
        Task { await KeychainService.shared.ensureVaultKeyExists() }
        Task { @MainActor in
            let events = (try? sharedModelContainer.mainContext.fetch(FetchDescriptor<SpecialDay>())) ?? []
            WidgetSummaryService.refresh(events: events)
        }
        // A cold launch caused by opening a .mvbackup: the URL was captured by
        // `AppDelegate` before this scene existed, so it is collected exactly once
        // here. The import screen is only presented after the vault is unlocked.
        if let url = appDelegate.takePendingLaunchURL() {
            appState.openBackupDocument(at: url)
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .inactive:
            PrivacyShield.shared.showShield()
        case .background:
            PrivacyShield.shared.showShield()
            appState.didEnterBackground()
        case .active:
            if !(UIScreen.main.isCaptured && AppSettingsStore.lockOnScreenCapture) {
                PrivacyShield.shared.hideShield()
            }
            appState.didBecomeActive()
        default: break
        }
    }
}
