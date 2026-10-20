import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var context
    @Query private var media: [VaultMedia]
    @Query private var albums: [VaultAlbum]
    @Query private var events: [SpecialDay]
    @State private var showingPINSetup = false
    @State private var showingDecoyPINSetup = false
    @State private var showingStorage = false
    @State private var showingDuplicates = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var autoLock = AppSettingsStore.autoLockTimeout
    @State private var notificationPrivacy = AppSettingsStore.notificationPrivacyMode
    @State private var lockOnCapture = AppSettingsStore.lockOnScreenCapture
    @State private var panicFaceDown = AppSettingsStore.panicFaceDownLock
    @State private var securityEventCount = 0

    private let lockOptions = [(0, "Immediately"), (30, "30 seconds"), (60, "1 minute"), (300, "5 minutes")]

    /// Options shown in the picker. "Never" is appended only when the device can still
    /// be re-locked some other way, so it is never offered as a one-way door.
    private var lockPickerOptions: [(Int, String)] {
        AppSettingsStore.neverAutoLockAllowed
            ? lockOptions + [(AppSettingsStore.neverLocks, "Never")]
            : lockOptions
    }

    private var stats: StorageService.Stats {
        guard !appState.isDecoyMode else { return StorageService.Stats() }
        return StorageService.shared.stats(media: media, albums: albums)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Face ID / Biometrics", isOn: Binding(
                        get: { AppSettingsStore.biometricEnabled },
                        set: { AppSettingsStore.setBiometricEnabled($0) }
                    ))
                    .disabled(!PINService.shared.isEnabled)
                    if PINService.shared.isEnabled {
                        Button("Disable PIN", role: .destructive) {
                            PINService.shared.disable()
                            Haptics.success()
                        }
                        if !appState.isDecoyMode {
                            if PINService.shared.isDecoyEnabled {
                                Button("Disable Decoy PIN", role: .destructive) {
                                    PINService.shared.disableDecoy()
                                    Haptics.success()
                                }
                            } else {
                                Button("Set up Decoy PIN") {
                                    showingDecoyPINSetup = true
                                }
                            }
                        }
                    } else {
                        Button("Set up PIN") { showingPINSetup = true }
                    }
                    Picker("Auto-lock", selection: $autoLock) {
                        ForEach(lockPickerOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: autoLock) { _, v in AppSettingsStore.setAutoLock(v) }
                    Toggle("Lock on Screenshot / Recording", isOn: $lockOnCapture)
                        .onChange(of: lockOnCapture) { _, v in AppSettingsStore.setLockOnScreenCapture(v) }
                    Toggle("Face-Down Panic Lock", isOn: $panicFaceDown)
                        .onChange(of: panicFaceDown) { _, v in AppSettingsStore.setPanicFaceDownLock(v) }
                    if !appState.isDecoyMode {
                        NavigationLink {
                            SecurityAuditLogView()
                        } label: {
                            HStack {
                                Text("Security Audit Log")
                                Spacer()
                                if securityEventCount > 0 {
                                    Text("\(securityEventCount)")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(Color.red.opacity(0.15), in: Capsule())
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Security")
                } footer: {
                    // One footer for the whole section: SwiftUI allows a single footer,
                    // and both hints can apply at once (e.g. Never selected with no PIN).
                    VStack(alignment: .leading, spacing: 6) {
                        if autoLock == AppSettingsStore.neverLocks {
                            Text("MyVault will not lock itself when you switch away. It still locks when you tap Lock Now or relaunch the app. Turn on Face ID or set a PIN so you can lock the vault on demand.")
                        } else if !AppSettingsStore.neverAutoLockAllowed {
                            Text("Set up a PIN or turn on Face ID to unlock the “Never” option. Without one, the vault would have no way back to a locked state.")
                        }
                        if !PINService.shared.isEnabled {
                            Text("Set up a PIN first if you want to turn Face ID off; otherwise biometrics are the only way to unlock.")
                        }
                    }
                }
                Section {
                    HStack {
                        Text("Permission")
                        Spacer()
                        Text(statusText).foregroundStyle(.secondary)
                    }
                    if notifStatus == .denied {
                        Button("Open Settings") { NotificationService.shared.openSettings() }
                    } else if notifStatus == .notDetermined {
                        Button("Enable Notifications") {
                            Task { _ = await NotificationService.shared.requestAuthorization() }
                        }
                    }
                    Toggle("Hide details on Lock Screen", isOn: $notificationPrivacy)
                        .accessibilityHint("Removes event names from reminder notifications.")
                        .onChange(of: notificationPrivacy) { _, value in
                            AppSettingsStore.setNotificationPrivacyMode(value)
                            WidgetSummaryService.refresh(events: events, privacyMode: value)
                            // Re-apply immediately so reminders already scheduled with an
                            // event title stop exposing it.
                            Task { await NotificationService.shared.rescheduleAll(events) }
                        }
                } header: {
                    Text("Notifications")
                } footer: {
                    // Built as two branches rather than a ternary: a long inline
                    // conditional inside a ViewBuilder confuses type inference.
                    if notificationPrivacy {
                        Text("Reminders will say “You have a special day coming up” instead of naming the event, so a glance at your Lock Screen reveals nothing.")
                    } else {
                        Text("Reminders include the event name and appear on your Lock Screen.")
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $themeManager.mode) {
                        ForEach(AppThemeMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    Picker("Accent", selection: $themeManager.accent) {
                        ForEach(AppAccent.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                }
                Section("Storage") {
                    HStack { Text("Vault size"); Spacer(); Text(StorageService.formatted(stats.totalBytes)).foregroundStyle(.secondary) }
                    Button("Manage Storage") { showingStorage = true }
                    NavigationLink("Recently Deleted") { TrashView() }
                    Button("Find Duplicates") { showingDuplicates = true }
                }
                Section("Privacy") {
                    Label("No account required. Your vault stays on this device unless you enable backup.", systemImage: "lock.fill")
                    Label("Photos are encrypted with AES-GCM. Keys live in the Keychain.", systemImage: "key.fill")
                }
                Section("Backup") {
                    NavigationLink {
                        BackupRestoreView()
                    } label: {
                        Label("Backup & Restore", systemImage: "lock.doc")
                    }
                    NavigationLink("Encrypted iCloud Sync") { BackupSettingsView() }
                }
                Section("About") {
                    HStack { Text("Version"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0").foregroundStyle(.secondary) }
                    HStack { Text("Build"); Spacer(); Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPINSetup) { PINSetupView() }
            .sheet(isPresented: $showingDecoyPINSetup) { DecoyPINSetupView() }
            .sheet(isPresented: $showingStorage) { StorageView() }
            .sheet(isPresented: $showingDuplicates) { DuplicatesView() }
            .onAppear {
                securityEventCount = appState.isDecoyMode ? 0 : PINService.shared.securityEvents().count
            }
            .task {
                notifStatus = await NotificationService.shared.authorizationStatus()
                // If "Never" is stored but is no longer a safe choice — for example the
                // PIN was disabled after it was selected — the picker would have no
                // matching tag and would render blank. Repair the stored value so the
                // setting always reflects something the UI can show and the app obeys.
                if autoLock == AppSettingsStore.neverLocks, !AppSettingsStore.neverAutoLockAllowed {
                    autoLock = 60
                    AppSettingsStore.setAutoLock(60)
                }
            }
        }
    }

    private var statusText: String {
        switch notifStatus {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .provisional: return "Provisional"
        default: return "Not asked"
        }
    }
}

struct StorageView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @Query private var media: [VaultMedia]
    @Query private var albums: [VaultAlbum]
    @State private var confirmingClear = false
    @State private var integrityReport: StorageService.IntegrityReport?

    private var stats: StorageService.Stats {
        guard !appState.isDecoyMode else { return StorageService.Stats() }
        return StorageService.shared.stats(media: media, albums: albums)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Usage") {
                    HStack { Text("Total vault"); Spacer(); Text(StorageService.formatted(stats.totalBytes)) }
                    HStack { Text("Photos"); Spacer(); Text(StorageService.formatted(stats.photoBytes)) }
                    HStack { Text("Videos"); Spacer(); Text(StorageService.formatted(stats.videoBytes)) }
                    HStack { Text("Files"); Spacer(); Text("\(stats.fileCount)") }
                    HStack { Text("Albums"); Spacer(); Text("\(stats.albumCount)") }
                }
                if !appState.isDecoyMode {
                    Section {
                        Button {
                            integrityReport = StorageService.shared.verifyAndRepairIntegrity(media: media)
                            Haptics.success()
                        } label: {
                            Label("Verify & Repair Vault Integrity", systemImage: "checkmark.shield")
                        }
                    } footer: {
                        Text("Verifies every encrypted item against its SHA-256 hash and removes any unreferenced ciphertext blobs.")
                    }
                }
                Section {
                    Button("Empty Trash", role: .destructive) { confirmingClear = true }
                }
            }
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert(
                "Vault Integrity Report",
                isPresented: Binding(
                    get: { integrityReport != nil },
                    set: { if !$0 { integrityReport = nil } }
                ),
                presenting: integrityReport
            ) { _ in
                Button("OK", role: .cancel) { integrityReport = nil }
            } message: { report in
                Text(report.summaryMessage)
            }
            .confirmationDialog("Permanently delete everything in trash?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
                    guard !appState.isDecoyMode else { return }
                    for m in media where m.isInTrash {
                        VaultStorageService.shared.delete(fileName: m.encryptedFileName)
                        context.delete(m)
                    }
                    try? context.save()
                    Haptics.success()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct SecurityAuditLogView: View {
    @State private var events: [PINService.SecurityEvent] = []

    var body: some View {
        Group {
            if events.isEmpty {
                MVEmptyState(
                    symbol: "checkmark.shield.fill",
                    title: "No Security Alerts",
                    subtitle: "Failed PIN attempts and screen-capture auto-locks will appear here."
                )
            } else {
                List {
                    Section {
                        ForEach(events) { event in
                            HStack(spacing: 12) {
                                Image(systemName: event.triggeredLockout ? "exclamationmark.lock.fill" : "exclamationmark.shield.fill")
                                    .foregroundStyle(event.triggeredLockout ? .red : .orange)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.note ?? "Incorrect PIN attempt #\(event.attemptNumber)")
                                        .font(MVFont.headline)
                                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if event.triggeredLockout {
                                        Text("Triggered cooldown lockout")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Recorded Events (\(events.count))")
                    }
                }
            }
        }
        .navigationTitle("Security Audit Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !events.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Log", role: .destructive) {
                        PINService.shared.clearSecurityEvents()
                        events = []
                        Haptics.success()
                    }
                }
            }
        }
        .onAppear {
            events = PINService.shared.securityEvents()
        }
    }
}

struct DuplicatesView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @Query private var media: [VaultMedia]
    @State private var alertMessage: String?

    private var groups: [[VaultMedia]] {
        guard !appState.isDecoyMode else { return [] }
        return StorageService.shared.duplicateGroups(in: media)
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    MVEmptyState(
                        symbol: "doc.on.doc",
                        title: "No duplicates",
                        subtitle: "Potential duplicates found will appear here for your review."
                    )
                } else {
                    List {
                        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                            Section {
                                ForEach(group) { item in
                                    HStack(spacing: 12) {
                                        MediaThumbnailView(item: item, pixelSize: 120)
                                            .frame(width: 48, height: 48)
                                            .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.fileName.isEmpty ? (item.isVideo ? "Video" : "Photo") : item.fileName)
                                                .font(MVFont.headline)
                                                .lineLimit(1)
                                            Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(StorageService.formatted(item.fileSize))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button("Trash", role: .destructive) {
                                            trashSingle(item)
                                        }
                                    }
                                }
                                Button(role: .destructive) {
                                    cleanUpGroup(group)
                                } label: {
                                    Label(
                                        "Keep 1, Move \(group.count - 1) to Recently Deleted",
                                        systemImage: "trash"
                                    )
                                }
                            } header: {
                                Text("Duplicate group \(index + 1) · \(group.count) identical items")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !groups.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clean Up All", role: .destructive) {
                            cleanUpAllGroups()
                        }
                    }
                }
            }
            .alert("Duplicates", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private func trashSingle(_ item: VaultMedia) {
        item.isInTrash = true
        item.trashedAt = Date()
        item.albumIDs.removeAll()
        item.album = nil
        context.saveReporting { _ in
            alertMessage = "The duplicate could not be moved to Recently Deleted."
        }
        Haptics.success()
    }

    private func cleanUpGroup(_ group: [VaultMedia]) {
        let removed = StorageService.shared.moveDuplicatesToTrash(in: group)
        guard removed > 0 else { return }
        context.saveReporting { _ in
            alertMessage = "The duplicates could not be moved to Recently Deleted."
        }
        Haptics.success()
    }

    private func cleanUpAllGroups() {
        var total = 0
        for group in groups {
            total += StorageService.shared.moveDuplicatesToTrash(in: group)
        }
        guard total > 0 else { return }
        context.saveReporting { _ in
            alertMessage = "Some duplicates could not be moved to Recently Deleted."
        }
        Haptics.success()
    }
}

struct BackupSettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var metadataList: [BackupMetadata]
    @State private var enabled = BackupService.shared.isEnabled
    @State private var statusMessage: String?

    private var metadata: BackupMetadata? { metadataList.first }

    var body: some View {
        List {
            Section {
                Toggle("Encrypted iCloud Backup", isOn: $enabled)
                    .onChange(of: enabled) { _, value in
                        BackupService.shared.isEnabled = value
                        let meta = BackupService.shared.fetchOrCreateMetadata(in: context)
                        meta.isEnabled = value
                        try? context.save()
                        if value && BackupService.shared.isiCloudAvailable {
                            syncNow()
                        } else {
                            Haptics.success()
                        }
                    }
                if enabled {
                    Button {
                        syncNow()
                    } label: {
                        Label("Sync Encrypted Blobs Now", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    .disabled(!BackupService.shared.isiCloudAvailable)
                }
            } header: {
                Text("Backup")
            } footer: {
                Text(BackupService.shared.isiCloudAvailable
                    ? "Only AES-GCM ciphertext is uploaded. Your key stays in this device's Keychain, so enable this only if you understand a new device cannot read the backup without a key transfer."
                    : "iCloud is not signed in on this device. Local-only mode keeps everything on-device.")
            }

            if let metadata, let lastBackupAt = metadata.lastBackupAt {
                Section("Last Sync") {
                    HStack {
                        Text("Last synced")
                        Spacer()
                        Text(lastBackupAt.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Encrypted blobs")
                        Spacer()
                        Text("\(metadata.encryptedItemCount)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Modes") {
                Label("Local-only: nothing leaves this device.", systemImage: "iphone")
                Label("Encrypted backup: ciphertext blobs sync via iCloud Drive.", systemImage: "icloud")
            }
        }
        .navigationTitle("Backup")
        .alert("iCloud Sync", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private func syncNow() {
        do {
            let updated = try BackupService.shared.syncEncryptedBlobs(in: context)
            Haptics.success()
            statusMessage = "Synced \(updated.encryptedItemCount) encrypted \(updated.encryptedItemCount == 1 ? "item" : "items") to iCloud Drive."
        } catch {
            Haptics.error()
            statusMessage = error.localizedDescription
        }
    }
}
