import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.modelContext) private var context
    @Query private var media: [VaultMedia]
    @Query private var albums: [VaultAlbum]
    @Query private var events: [SpecialDay]
    @State private var showingPINSetup = false
    @State private var showingStorage = false
    @State private var showingDuplicates = false
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var autoLock = AppSettingsStore.autoLockTimeout
    @State private var notificationPrivacy = AppSettingsStore.notificationPrivacyMode

    private let lockOptions = [(0, "Immediately"), (30, "30 seconds"), (60, "1 minute"), (300, "5 minutes")]

    /// Options shown in the picker. "Never" is appended only when the device can still
    /// be re-locked some other way, so it is never offered as a one-way door.
    private var lockPickerOptions: [(Int, String)] {
        AppSettingsStore.neverAutoLockAllowed
            ? lockOptions + [(AppSettingsStore.neverLocks, "Never")]
            : lockOptions
    }

    private var stats: StorageService.Stats {
        StorageService.shared.stats(media: media, albums: albums)
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
                    } else {
                        Button("Set up PIN") { showingPINSetup = true }
                    }
                    Picker("Auto-lock", selection: $autoLock) {
                        ForEach(lockPickerOptions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .onChange(of: autoLock) { _, v in AppSettingsStore.setAutoLock(v) }
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
            .sheet(isPresented: $showingStorage) { StorageView() }
            .sheet(isPresented: $showingDuplicates) { DuplicatesView() }
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
    @Query private var media: [VaultMedia]
    @Query private var albums: [VaultAlbum]
    @State private var confirmingClear = false

    private var stats: StorageService.Stats {
        StorageService.shared.stats(media: media, albums: albums)
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
                Section {
                    Button("Empty Trash", role: .destructive) { confirmingClear = true }
                }
            }
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Permanently delete everything in trash?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) {
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

struct DuplicatesView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var media: [VaultMedia]

    private var groups: [[VaultMedia]] {
        StorageService.shared.duplicateGroups(in: media)
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    MVEmptyState(symbol: "doc.on.doc", title: "No duplicates", subtitle: "Potential duplicates found will appear here for your review.")
                } else {
                    List {
                        ForEach(groups.indices, id: \.self) { i in
                            Section("Potential duplicates found — group \(i + 1)") {
                                ForEach(groups[i]) { m in
                                    HStack {
                                        Image(systemName: m.isVideo ? "video.fill" : "photo.fill")
                                        Text(m.fileName).lineLimit(1)
                                        Spacer()
                                        Text(StorageService.formatted(m.fileSize)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Duplicates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct BackupSettingsView: View {
    @State private var enabled = UserDefaults.standard.bool(forKey: "mv.backupEnabled")
    var body: some View {
        List {
            Section {
                Toggle("Encrypted iCloud Backup", isOn: $enabled)
                    .onChange(of: enabled) { _, v in
                        UserDefaults.standard.set(v, forKey: "mv.backupEnabled")
                        Haptics.success()
                    }
            } header: {
                Text("Backup")
            } footer: {
                Text(BackupService.shared.isiCloudAvailable
                    ? "Only AES-GCM ciphertext is uploaded. Your key stays in this device's Keychain, so enable this only if you understand a new device cannot read the backup without a key transfer."
                    : "iCloud is not signed in on this device. Local-only mode keeps everything on-device.")
            }
            Section("Modes") {
                Label("Local-only: nothing leaves this device.", systemImage: "iphone")
                Label("Encrypted backup: ciphertext blobs sync via iCloud Drive.", systemImage: "icloud")
            }
        }
        .navigationTitle("Backup")
    }
}
