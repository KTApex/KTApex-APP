import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Guidance for a *backup* password.
///
/// The password is the only thing protecting a file that leaves the device, so the
/// app asks for more than it does for a PIN. This is deliberately simple, honest
/// advice rather than a fake entropy score, and it is unit-tested.
enum BackupPasswordGuidance {
    static let minimumLength = 8

    struct Assessment: Equatable {
        var label: String
        var detail: String
        var isAcceptable: Bool
        var isStrong: Bool
    }

    static func assess(_ password: String) -> Assessment {
        let length = password.count
        let hasLetter = password.contains { $0.isLetter }
        let hasDigit = password.contains { $0.isNumber }
        let hasSymbol = password.contains { !$0.isLetter && !$0.isNumber }
        let storageAdvice = "Store this password somewhere safe. MyVault cannot recover it, and without it the backup cannot be opened."

        guard length >= minimumLength else {
            return Assessment(
                label: "Too short",
                detail: "Use at least \(minimumLength) characters. A longer phrase you can remember beats a short puzzle you cannot.",
                isAcceptable: false,
                isStrong: false
            )
        }
        if !hasLetter || !hasDigit {
            return Assessment(
                label: "Weak",
                detail: "Add both letters and numbers (or use a longer passphrase) so the backup cannot be guessed if the file is shared.",
                isAcceptable: true,
                isStrong: false
            )
        }
        if length >= 12 && hasSymbol {
            return Assessment(label: "Strong", detail: storageAdvice, isAcceptable: true, isStrong: true)
        }
        return Assessment(label: "Good", detail: storageAdvice, isAcceptable: true, isStrong: false)
    }
}

/// Settings → Backup & Restore.
///
/// Creating a backup writes one encrypted `.mvbackup` file and hands it to the
/// system share sheet, so it can go to Files, AirDrop, a messaging app or an
/// external drive. No iCloud account is required, and nothing leaves the device
/// until the user chooses a destination.
struct BackupRestoreView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// One sheet at a time: several `.sheet` modifiers on one view are unreliable,
    /// so every presentation goes through this enum.
    private enum ActiveSheet: Identifiable {
        case create
        case restorePassword
        case preview(PortableBackupService.Preview)

        var id: String {
            switch self {
            case .create: return "create"
            case .restorePassword: return "password"
            case .preview(let preview): return "preview-\(preview.createdAt.timeIntervalSince1970)"
            }
        }
    }

    @State private var activeSheet: ActiveSheet?
    @State private var showingImporter = false
    @State private var restorePassword = ""
    @State private var selectedBackupURL: URL?
    @State private var inspectedVersion: Int?
    @State private var progress: PortableBackupService.Progress?
    @State private var artifact: PortableBackupService.Artifact?
    @State private var shareBundle: ShareService.Prepared?
    @State private var summary: PortableBackupService.Summary?
    @State private var alertMessage: String?
    @State private var cancelFlag = CancelFlag()
    @State private var isWorking = false

    /// Split into layers on purpose: keeping the list, the sheets and the alerts in
    /// one expression makes the type checker give up on it ("unable to type-check
    /// this expression in reasonable time").
    var body: some View {
        list
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $activeSheet) { sheet in
                sheetContent(sheet)
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: false
            ) { result in
                handlePickedFile(result)
            }
            .alert("Backup", isPresented: alertBinding) {
                Button("OK", role: .cancel) { alertMessage = nil }
            } message: {
                Text(alertMessage ?? "")
            }
            .alert(
                summary?.headline ?? "",
                isPresented: summaryBinding,
                presenting: summary
            ) { _ in
                Button("OK", role: .cancel) { summary = nil }
            } message: { value in
                Text(summaryDetail(value))
            }
            .vaultShareSheet(prepared: $shareBundle)
            .onDisappear { discardIncomingCopy() }
    }

    private var list: some View {
        List {
            actionsSection
            progressSection
            artifactSection
            limitsSection
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Haptics.tap()
                activeSheet = .create
            } label: {
                Label("Create Backup", systemImage: "lock.doc")
            }
            .disabled(isWorking)

            Button {
                Haptics.tap()
                showingImporter = true
            } label: {
                Label("Import Backup", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(isWorking)
        } header: {
            Text("Portable backup")
        } footer: {
            Text("A backup is one encrypted file (MyVault_Backup.mvbackup). It holds your media, albums, favorites, special days and reminders — encrypted with a password you choose, so it can be restored on another iPhone without an iCloud account.")
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if let progress {
            Section {
                MVProgressCard(
                    title: progress.stage.title,
                    detail: progress.detail,
                    progress: progress.fraction,
                    onCancel: progress.stage == .committing ? nil : { cancelFlag.cancel() }
                )
            }
        }
    }

    @ViewBuilder
    private var artifactSection: some View {
        if let artifact {
            Section("Last backup") {
                MVInfoRow(label: "File", value: artifact.fileName)
                MVInfoRow(label: "Items", value: "\(artifact.itemCount)")
                MVInfoRow(label: "Size", value: artifact.sizeText)
                Button {
                    shareBundle = artifact.share
                } label: {
                    Label("Share Backup", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private var limitsSection: some View {
        Section("What is not included") {
            Label("Your vault encryption key, PIN or Face ID settings", systemImage: "key.slash")
            Label("Restoring adds items to this vault and never deletes what is already here", systemImage: "plus.circle")
            Label("Items you already have (matched by content) are left untouched", systemImage: "checkmark.circle")
            Label("Nothing is uploaded unless you share the file yourself", systemImage: "icloud.slash")
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .create:
            CreateBackupSheet { password in
                activeSheet = nil
                createBackup(password: password)
            }
        case .restorePassword:
            RestorePasswordSheet(
                password: $restorePassword,
                fileName: selectedBackupURL?.lastPathComponent ?? ""
            ) {
                activeSheet = nil
                preparePreview()
            }
        case .preview(let preview):
            RestorePreviewSheet(preview: preview) {
                activeSheet = nil
                performRestore()
            }
        }
    }

    private func summaryDetail(_ value: PortableBackupService.Summary) -> String {
        value.detailLines.isEmpty ? "Your vault is unchanged." : value.detailLines.joined(separator: "\n")
    }

    // MARK: - Bindings

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    private var summaryBinding: Binding<Bool> {
        Binding(get: { summary != nil }, set: { if !$0 { summary = nil } })
    }

    // MARK: - Creating

    private func createBackup(password: String) {
        guard !isWorking else { return }
        isWorking = true
        cancelFlag.reset()
        progress = PortableBackupService.Progress(stage: .preparing, fraction: 0, detail: nil)
        Task {
            do {
                let result = try await PortableBackupService.shared.createBackup(
                    password: password,
                    context: context,
                    progress: { update in progress = update }
                )
                progress = nil
                isWorking = false
                artifact = result
                shareBundle = result.share
                if result.skippedItems > 0 {
                    alertMessage = "The backup was created, but \(result.skippedItems) vault item\(result.skippedItems == 1 ? "" : "s") had no encrypted file on disk, so \(result.skippedItems == 1 ? "it was" : "they were") left out."
                }
            } catch {
                progress = nil
                isWorking = false
                Haptics.error()
                alertMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Restoring

    /// The `fileImporter` completion hands back an array even when only one file can
    /// be chosen, so the first (and only) URL is unwrapped here.
    private func handlePickedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure:
            alertMessage = "That file could not be opened."
        case .success(let urls):
            guard let url = urls.first else {
                alertMessage = "That file could not be opened."
                return
            }
            // A file chosen in another app's sandbox needs explicit access.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // Container and version checks happen *before* a password is asked
                // for, so a newer format is reported as "update the app" rather than
                // as a damaged file.
                let header = try PortableBackupService.inspect(url)
                // Copied into scratch space under a name this app controls, so the
                // security scope is only needed for a moment and a hostile file name
                // never reaches the file system.
                let directory = try SecureScratch.makeDirectory(prefix: "incoming")
                let local: URL
                do {
                    local = try SecureScratch.copy(url, named: "incoming.mvbackup", in: directory)
                } catch {
                    SecureScratch.removeDirectory(directory)
                    throw error
                }
                discardIncomingCopy()
                selectedBackupURL = local
                inspectedVersion = Int(header.formatVersion)
                restorePassword = ""
                activeSheet = .restorePassword
            } catch {
                Haptics.error()
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Drops the scratch copy of the chosen file once it is no longer needed, so a
    /// backup does not linger in temporary storage after the sheet is dismissed.
    /// Only ever removes a directory this screen created.
    private func discardIncomingCopy() {
        guard let url = selectedBackupURL else { return }
        let directory = url.deletingLastPathComponent()
        if directory.lastPathComponent.hasPrefix("incoming-") {
            SecureScratch.removeDirectory(directory)
        }
        selectedBackupURL = nil
    }

    private func preparePreview() {
        guard let url = selectedBackupURL else { return }
        let password = restorePassword
        isWorking = true
        progress = PortableBackupService.Progress(stage: .staging, fraction: 0, detail: "Checking the password")
        Task {
            do {
                let preview = try await PortableBackupService.shared.previewRestore(from: url, password: password)
                progress = nil
                isWorking = false
                if preview.manifest.media.isEmpty && preview.manifest.specialDays.isEmpty {
                    alertMessage = "This backup does not contain any restorable items."
                } else {
                    activeSheet = .preview(preview)
                }
            } catch {
                progress = nil
                isWorking = false
                Haptics.error()
                // One message covers a wrong password, a damaged file and a tampered
                // file: the user learns nothing about the backup's internals.
                alertMessage = error.localizedDescription
            }
        }
    }

    private func performRestore() {
        guard let url = selectedBackupURL, !isWorking else { return }
        let password = restorePassword
        isWorking = true
        cancelFlag.reset()
        progress = PortableBackupService.Progress(stage: .staging, fraction: 0, detail: nil)
        Task {
            do {
                let result = try await PortableBackupService.shared.restore(
                    from: url,
                    password: password,
                    context: context,
                    progress: { update in progress = update },
                    cancelFlag: cancelFlag
                )
                progress = nil
                isWorking = false
                restorePassword = ""
                refreshDependentState()
                Haptics.success()
                summary = result
            } catch {
                progress = nil
                isWorking = false
                restorePassword = ""
                Haptics.error()
                alertMessage = error.localizedDescription
            }
        }
    }

    /// Restored special days have to reach the widget, and cached thumbnails for
    /// media that no longer exists must go.
    private func refreshDependentState() {
        let events = (try? context.fetch(FetchDescriptor<SpecialDay>())) ?? []
        WidgetSummaryService.refresh(events: events)
        ThumbnailCache.shared.clear()
    }
}

// MARK: - Sheets

private struct CreateBackupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    let onCreate: (String) -> Void

    private var assessment: BackupPasswordGuidance.Assessment {
        BackupPasswordGuidance.assess(password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Backup password", text: $password)
                        .textContentType(.newPassword)
                        .accessibilityLabel("Backup password")
                    SecureField("Confirm password", text: $confirmation)
                        .textContentType(.newPassword)
                        .accessibilityLabel("Confirm backup password")
                } header: {
                    Text("Password")
                } footer: {
                    Text("This password protects the backup file itself. It is not your vault PIN, and it is never stored anywhere — if you lose it, nobody can open the backup, including us.")
                }

                Section("Strength") {
                    HStack {
                        Text("Rating")
                        Spacer()
                        Text(assessment.label)
                            .foregroundStyle(assessment.isAcceptable ? (assessment.isStrong ? .green : .orange) : .red)
                    }
                    Text(assessment.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        Haptics.success()
                        onCreate(password)
                        password = ""
                        confirmation = ""
                    } label: {
                        Label("Create Backup", systemImage: "lock.doc")
                    }
                    .disabled(!assessment.isAcceptable || password != confirmation)
                } footer: {
                    if password != confirmation && !confirmation.isEmpty {
                        Text("The passwords do not match yet.")
                    }
                }
            }
            .navigationTitle("Create Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}

private struct RestorePasswordSheet: View {
    @Binding var password: String
    let fileName: String
    let onContinue: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Backup password", text: $password)
                        .textContentType(.password)
                        .accessibilityLabel("Backup password")
                } header: {
                    Text(fileName)
                } footer: {
                    Text("Enter the password used when this backup was created. MyVault cannot recover it.")
                }
                Section {
                    Button {
                        Haptics.tap()
                        onContinue()
                    } label: {
                        Label("Continue", systemImage: "arrow.right.circle")
                    }
                    .disabled(password.isEmpty)
                }
            }
            .navigationTitle("Unlock Backup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct RestorePreviewSheet: View {
    let preview: PortableBackupService.Preview
    let onRestore: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section("This backup contains") {
                    ForEach(preview.lines, id: \.self) { line in
                        Label(line, systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                }
                Section("Backup") {
                    MVInfoRow(label: "Created", value: preview.createdAt.formatted(date: .abbreviated, time: .shortened))
                    MVInfoRow(label: "App version", value: preview.appVersion)
                    MVInfoRow(label: "Format", value: "\(preview.formatVersion)")
                }
                Section {
                    Text("Restoring adds these items to your vault. Nothing already in the vault is deleted or replaced, and items you already have are skipped.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        Haptics.tap()
                        onRestore()
                    } label: {
                        Label("Restore These Items", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .navigationTitle("Restore Preview")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension PortableBackupService.Preview: Identifiable {
    var id: Date { createdAt }
}
