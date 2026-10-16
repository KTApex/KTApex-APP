import Foundation
import SwiftData

/// Portable, password-protected backups (`MyVault_Backup_YYYY-MM-DD_HH-mm.mvbackup`).
///
/// Four decisions shape this service:
///
/// 1. **The whole file is one authenticated encrypted stream.** There is no
///    plaintext archive inside a wrapper: without the password nothing is readable
///    and nothing is partially recoverable.
/// 2. **Media is re-encrypted with a key derived from the user's backup password**,
///    not the device vault key. The vault key is `ThisDeviceOnly`, so a backup made
///    from it could never be opened anywhere else — the password-derived key is what
///    makes a backup portable.
/// 3. **Restore never modifies existing data.** It stages, validates, and then adds.
///    An item already in the vault (matched by content hash) is skipped, and a
///    failure before the final save removes everything the restore created.
/// 4. **No credentials are ever written.** No PIN verifier, no vault key, no
///    lockout state, no `UserDefaults` dumps.
@MainActor
final class PortableBackupService: ObservableObject {
    static let shared = PortableBackupService()
    private init() {}

    // MARK: - Types

    struct Progress: Equatable {
        enum Stage: String, Equatable {
            case preparing, collecting, encrypting, verifying, staging, committing, finished

            var title: String {
                switch self {
                case .preparing: return "Preparing"
                case .collecting: return "Collecting vault items"
                case .encrypting: return "Encrypting backup"
                case .verifying: return "Verifying backup"
                case .staging: return "Reading backup"
                case .committing: return "Restoring"
                case .finished: return "Finishing"
                }
            }
        }

        var stage: Stage
        var fraction: Double
        var detail: String?
    }

    struct Artifact {
        var url: URL
        var fileName: String
        var itemCount: Int
        var byteCount: Int
        var createdAt: Date
        /// Vault rows whose ciphertext was missing and therefore not included.
        var skippedItems: Int
        /// Ready to hand to `vaultShareSheet`; the caller owns its lifetime.
        var share: ShareService.Prepared

        var sizeText: String { StorageService.formatted(byteCount) }
    }

    struct Summary: Equatable {
        var media: Int = 0
        var albums: Int = 0
        var specialDays: Int = 0
        var reminders: Int = 0
        var skippedDuplicates: Int = 0
        var verified: Int = 0
        var failedVerification: Int = 0
        var bytes: Int = 0

        var isEmpty: Bool { media == 0 && albums == 0 && specialDays == 0 && reminders == 0 }

        var headline: String {
            if isEmpty && skippedDuplicates > 0 { return "Everything in this backup is already in your vault" }
            if isEmpty { return "The backup did not contain anything to restore" }
            var parts: [String] = []
            if media > 0 { parts.append("\(media) item\(media == 1 ? "" : "s")") }
            if albums > 0 { parts.append("\(albums) album\(albums == 1 ? "" : "s")") }
            if specialDays > 0 { parts.append("\(specialDays) special day\(specialDays == 1 ? "" : "s")") }
            if reminders > 0 { parts.append("\(reminders) reminder\(reminders == 1 ? "" : "s")") }
            return "Restored " + parts.joined(separator: ", ")
        }

        var detailLines: [String] {
            var lines: [String] = []
            if bytes > 0 { lines.append("\(StorageService.formatted(bytes)) of media") }
            if skippedDuplicates > 0 {
                lines.append("\(skippedDuplicates) item\(skippedDuplicates == 1 ? " was" : "s were") already in your vault and left untouched")
            }
            if verified > 0 { lines.append("\(verified) item\(verified == 1 ? "" : "s") verified by decrypting them again") }
            if failedVerification > 0 {
                lines.append("\(failedVerification) item\(failedVerification == 1 ? "" : "s") could not be verified — check those items in the vault")
            }
            return lines
        }
    }

    struct Preview: Equatable {
        var createdAt: Date
        var appVersion: String
        var formatVersion: Int
        var iterations: UInt32
        var lines: [String]
        var manifest: BackupManifest
    }

    /// One restored item on its way into the vault.
    private struct EncryptedItem: Sendable {
        var media: BackupManifest.Media
        var storedName: String
    }

    // MARK: - Naming

    nonisolated static func fileName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return "MyVault_Backup_\(formatter.string(from: date)).mvbackup"
    }

    nonisolated static func validate(password: String, confirmation: String) throws {
        guard password.count >= 8 else { throw BackupError.passwordTooShort }
        guard password == confirmation else { throw BackupError.passwordMismatch }
    }

    // MARK: - Inspection (no password needed)

    /// Reads the header only, so a backup from a newer version — or a file that is
    /// not a backup at all — is rejected before the user is asked for a password.
    nonisolated static func inspect(_ url: URL) throws -> BackupHeader {
        try BackupHeader.readHeader(from: url)
    }

    // MARK: - Creating a backup

    func createBackup(
        password: String,
        context: ModelContext,
        progress: @escaping (Progress) -> Void
    ) async throws -> Artifact {
        progress(Progress(stage: .preparing, fraction: 0, detail: nil))
        let plan = try buildPlan(context: context)
        guard !plan.entries.isEmpty else {
            throw BackupError.restoreFailed("There is nothing in the vault to back up yet.")
        }

        let directory = try SecureScratch.makeDirectory(prefix: "backup")
        let buildingURL = directory.appendingPathComponent("building.mvbackup")
        let artifactName = Self.fileName()
        let finalURL = directory.appendingPathComponent(artifactName)

        let manifestData = try BackupManifest.encoder().encode(plan.manifest)
        var entries: [BackupEntry] = [
            BackupEntry(name: BackupFormat.manifestEntryName, source: .data(manifestData), compress: true)
        ]
        entries.append(contentsOf: plan.entries)

        let monitor = startFileSizeMonitor(url: buildingURL, expectedBytes: plan.payloadBytes, progress: progress)
        let result: BackupArchive.WriteResult
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try BackupArchive.write(entries: entries, password: password, to: buildingURL)
            }.value
        } catch {
            monitor.cancel()
            SecureScratch.removeDirectory(directory)
            throw error
        }
        monitor.cancel()

        // Verify the artifact by opening it again. A backup that cannot be
        // decrypted is never offered to the user.
        progress(Progress(stage: .verifying, fraction: 0.9, detail: "Confirming the backup opens correctly"))
        let expectedCounts = plan.manifest.counts
        let verified = await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let verifyDirectory = try? SecureScratch.makeDirectory(prefix: "verify") else { return false }
            defer { SecureScratch.removeDirectory(verifyDirectory) }
            do {
                let readBack = try BackupArchive.read(
                    from: buildingURL, password: password, into: verifyDirectory, entryLimit: 1
                )
                guard let manifestURL = readBack.stagedFiles[BackupFormat.manifestEntryName] else { return false }
                let manifest = try BackupManifest.decoder().decode(
                    BackupManifest.self, from: try Data(contentsOf: manifestURL)
                )
                return manifest.counts == expectedCounts
            } catch {
                return false
            }
        }.value
        guard verified else {
            SecureScratch.removeDirectory(directory)
            throw BackupError.failedToWrite
        }

        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: finalURL.path) { try manager.removeItem(at: finalURL) }
            try manager.moveItem(at: buildingURL, to: finalURL)
        } catch {
            SecureScratch.removeDirectory(directory)
            throw BackupError.failedToWrite
        }

        progress(Progress(stage: .finished, fraction: 1, detail: nil))
        return Artifact(
            url: finalURL,
            fileName: artifactName,
            itemCount: plan.manifest.liveCount,
            byteCount: result.byteCount,
            createdAt: Date(),
            skippedItems: plan.skippedMissingFiles,
            share: ShareService.Prepared(urls: [finalURL], directory: directory, skipped: [])
        )
    }

    /// Removes a backup the user decided not to keep.
    func discard(_ artifact: Artifact) {
        SecureScratch.removeDirectory(artifact.share.directory)
    }

    /// Progress from the size of the file being written. Cheap, honest (it measures
    /// real bytes on disk) and it keeps all progress reporting on the main actor
    /// while the writer runs elsewhere.
    private func startFileSizeMonitor(
        url: URL,
        expectedBytes: Int,
        progress: @escaping (Progress) -> Void
    ) -> Task<Void, Never> {
        let expected = max(expectedBytes, 1)
        return Task { @MainActor in
            while !Task.isCancelled {
                let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                progress(Progress(
                    stage: .encrypting,
                    fraction: min(Double(written) / Double(expected), 1),
                    detail: "\(StorageService.formatted(written)) of about \(StorageService.formatted(expected))"
                ))
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// Same idea for staging: the decrypted files grow as the backup is read.
    private func startStagingMonitor(
        directory: URL,
        expectedBytes: Int,
        progress: @escaping (Progress) -> Void
    ) -> Task<Void, Never> {
        let expected = max(expectedBytes, 1)
        return Task { @MainActor in
            while !Task.isCancelled {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.fileSizeKey]
                )) ?? []
                let written = contents.reduce(0) { total, file in
                    total + ((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                progress(Progress(
                    stage: .staging,
                    fraction: min(Double(written) / Double(expected), 1),
                    detail: "\(StorageService.formatted(written)) of about \(StorageService.formatted(expected))"
                ))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    // MARK: - Building the plan (main actor / SwiftData)

    private struct BackupPlan {
        var manifest: BackupManifest
        var entries: [BackupEntry]
        var payloadBytes: Int
        var skippedMissingFiles: Int
    }

    private func buildPlan(context: ModelContext) throws -> BackupPlan {
        let media = (try? context.fetch(FetchDescriptor<VaultMedia>())) ?? []
        let albums = (try? context.fetch(FetchDescriptor<VaultAlbum>())) ?? []
        let events = (try? context.fetch(FetchDescriptor<SpecialDay>())) ?? []
        let reminders = (try? context.fetch(FetchDescriptor<ReminderConfiguration>())) ?? []
        let storedFiles = Set(VaultStorageService.shared.storedFileNames())

        var manifestMedia: [BackupManifest.Media] = []
        var entries: [BackupEntry] = []
        var skipped = 0
        var bytes = 0

        for (index, item) in media.enumerated() {
            let vaultURL = VaultStorageService.shared.vaultDirectory.appendingPathComponent(item.encryptedFileName)
            // A row whose ciphertext is gone cannot be restored, so it is reported
            // instead of producing a backup that fails its own verification.
            guard storedFiles.contains(item.encryptedFileName) else {
                skipped += 1
                continue
            }
            let entryName = "media-\(index)"
            entries.append(BackupEntry(name: entryName, source: .file(vaultURL, byteCount: item.fileSize)))
            manifestMedia.append(BackupManifest.Media(
                id: item.id,
                fileName: item.fileName,
                mediaType: item.mediaType,
                createdAt: item.createdAt,
                isFavorite: item.isFavorite,
                isInTrash: item.isInTrash,
                trashedAt: item.trashedAt,
                fileSize: item.fileSize,
                contentHash: item.contentHash,
                width: item.width,
                height: item.height,
                duration: item.duration,
                albumID: item.album?.id,
                entryName: entryName
            ))
            bytes += item.fileSize
        }

        let manifest = BackupManifest(
            schemaVersion: BackupManifest.currentSchema,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            counts: BackupManifest.Counts(
                media: manifestMedia.count,
                albums: albums.count,
                specialDays: events.count,
                trashedMedia: manifestMedia.filter { $0.isInTrash }.count,
                totalMediaBytes: bytes
            ),
            albums: albums.map {
                BackupManifest.Album(id: $0.id, name: $0.name, createdAt: $0.createdAt, coverMediaID: $0.coverMediaID)
            },
            media: manifestMedia,
            specialDays: events.map {
                BackupManifest.SpecialDay(
                    id: $0.id, title: $0.title, date: $0.date, notes: $0.notes,
                    typeRaw: $0.typeRaw, repeatsYearly: $0.repeatsYearly,
                    reminderDays: $0.reminderDays, reminderTimeHour: $0.reminderTimeHour,
                    reminderTimeMinute: $0.reminderTimeMinute, createdAt: $0.createdAt
                )
            },
            reminders: reminders.map {
                BackupManifest.Reminder(
                    id: $0.id, specialDayID: $0.specialDayID, daysBefore: $0.daysBefore,
                    timeHour: $0.timeHour, timeMinute: $0.timeMinute, isEnabled: $0.isEnabled
                )
            },
            settings: BackupManifest.Settings(
                autoLockSeconds: AppSettingsStore.autoLockTimeout,
                themeMode: UserDefaults.standard.string(forKey: "mv.theme"),
                accent: UserDefaults.standard.string(forKey: "mv.accent"),
                galleryColumns: UserDefaults.standard.object(forKey: "mv.galleryColumns") as? Int
            )
        )

        return BackupPlan(manifest: manifest, entries: entries, payloadBytes: bytes, skippedMissingFiles: skipped)
    }

    // MARK: - Preview

    /// Decrypts only the manifest, so the user can see what a backup holds before
    /// committing to a restore.
    func previewRestore(from url: URL, password: String) async throws -> Preview {
        try await Task.detached(priority: .userInitiated) { () -> Preview in
            guard let directory = try? SecureScratch.makeDirectory(prefix: "preview") else {
                throw BackupError.outOfSpace
            }
            defer { SecureScratch.removeDirectory(directory) }
            let result = try BackupArchive.read(from: url, password: password, into: directory, entryLimit: 1)
            guard let manifestURL = result.stagedFiles[BackupFormat.manifestEntryName] else {
                throw BackupError.corrupted
            }
            let manifest: BackupManifest
            do {
                manifest = try BackupManifest.decoder().decode(
                    BackupManifest.self, from: try Data(contentsOf: manifestURL)
                )
            } catch {
                throw BackupError.corrupted
            }
            guard manifest.schemaVersion <= BackupManifest.currentSchema else {
                throw BackupError.unsupportedVersion(manifest.schemaVersion)
            }
            return Preview(
                createdAt: manifest.createdAt,
                appVersion: manifest.appVersion,
                formatVersion: Int(result.header.formatVersion),
                iterations: result.header.iterations,
                lines: manifest.previewLines,
                manifest: manifest
            )
        }.value
    }

    // MARK: - Restore

    /// Transactional restore: stage → validate → encrypt → commit in one save.
    ///
    /// Cancelling during staging or encryption changes nothing. The commit itself is
    /// a single save, and if it fails everything created for it is removed.
    func restore(
        from url: URL,
        password: String,
        context: ModelContext,
        progress: @escaping (Progress) -> Void,
        cancelFlag: CancelFlag
    ) async throws -> Summary {
        progress(Progress(stage: .staging, fraction: 0, detail: nil))
        guard let staging = try? SecureScratch.makeDirectory(prefix: "restore") else { throw BackupError.outOfSpace }
        defer { SecureScratch.removeDirectory(staging) }

        // The decrypted payload is roughly the file size minus the header, so the
        // backup's own size is the right denominator for staging progress.
        let expectedBytes = max((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 1)
        let monitor = startStagingMonitor(directory: staging, expectedBytes: expectedBytes, progress: progress)

        let read: BackupArchive.ReadResult
        do {
            read = try await Task.detached(priority: .userInitiated) {
                try BackupArchive.read(
                    from: url, password: password, into: staging,
                    isCancelled: { cancelFlag.isCancelled }
                )
            }.value
        } catch {
            monitor.cancel()
            throw error
        }
        monitor.cancel()
        if cancelFlag.isCancelled { throw BackupError.cancelled }

        guard let manifestURL = read.stagedFiles[BackupFormat.manifestEntryName] else { throw BackupError.corrupted }
        let manifest: BackupManifest
        do {
            manifest = try BackupManifest.decoder().decode(
                BackupManifest.self, from: try Data(contentsOf: manifestURL)
            )
        } catch {
            throw BackupError.corrupted
        }
        guard manifest.schemaVersion <= BackupManifest.currentSchema else {
            throw BackupError.unsupportedVersion(manifest.schemaVersion)
        }

        // Confirm every referenced payload exists at the size the manifest claims,
        // before anything is written into the vault.
        for media in manifest.media {
            guard let stagedURL = read.stagedFiles[media.entryName] else { throw BackupError.corrupted }
            let size = (try? stagedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
            guard size == media.fileSize else { throw BackupError.corrupted }
        }

        progress(Progress(stage: .committing, fraction: 0, detail: nil))

        // --- Merge decisions, taken on the main actor ---
        let existingMedia = (try? context.fetch(FetchDescriptor<VaultMedia>())) ?? []
        let existingHashes = Set(existingMedia.map(\.contentHash).filter { !$0.isEmpty })
        let existingAlbums = (try? context.fetch(FetchDescriptor<VaultAlbum>())) ?? []
        let existingDays = (try? context.fetch(FetchDescriptor<SpecialDay>())) ?? []
        let existingReminders = (try? context.fetch(FetchDescriptor<ReminderConfiguration>())) ?? []

        let stagedForImport: [(BackupManifest.Media, URL)] = manifest.media.compactMap { media in
            guard let stagedURL = read.stagedFiles[media.entryName] else { return nil }
            return (media, stagedURL)
        }
        let duplicateCount = stagedForImport.filter { existingHashes.contains($0.0.contentHash) }.count

        // --- Phase A: write ciphertext, off the main actor. Nothing references it
        // yet, and `written` lets every failure path clean up exactly what exists.
        let written = FileNameCollector()
        var encrypted: [EncryptedItem] = []
        do {
            encrypted = try await Task.detached(priority: .userInitiated) { () -> [EncryptedItem] in
                var results: [EncryptedItem] = []
                var seen = existingHashes
                for (media, stagedURL) in stagedForImport {
                    if cancelFlag.isCancelled { throw BackupError.cancelled }
                    // Restoring something already present is a no-op, not an error.
                    if !media.contentHash.isEmpty, seen.contains(media.contentHash) { continue }
                    let data = try Data(contentsOf: stagedURL)
                    let storedName = try VaultStorageService.shared.storeEncrypted(data: data)
                    written.append(storedName)
                    seen.insert(media.contentHash)
                    results.append(EncryptedItem(media: media, storedName: storedName))
                }
                return results
            }.value
        } catch {
            for name in written.names { VaultStorageService.shared.delete(fileName: name) }
            throw error
        }

        // --- Phase B: one transaction for every row the backup contributes. ---
        do {
            var albumsByID: [String: VaultAlbum] = [:]
            for album in existingAlbums { albumsByID[album.id] = album }
            var createdAlbums = 0
            for album in manifest.albums where albumsByID[album.id] == nil {
                let model = VaultAlbum(name: album.name)
                model.id = album.id
                model.createdAt = album.createdAt
                model.coverMediaID = album.coverMediaID
                context.insert(model)
                albumsByID[album.id] = model
                createdAlbums += 1
            }

            for item in encrypted {
                let media = item.media
                let model = VaultMedia(
                    fileName: media.fileName,
                    encryptedFileName: item.storedName,
                    mediaType: media.mediaType,
                    fileSize: media.fileSize,
                    contentHash: media.contentHash
                )
                model.id = media.id
                model.createdAt = media.createdAt
                model.isFavorite = media.isFavorite
                model.isInTrash = media.isInTrash
                model.trashedAt = media.trashedAt
                model.width = media.width
                model.height = media.height
                model.duration = media.duration
                if let albumID = media.albumID { model.album = albumsByID[albumID] }
                context.insert(model)
            }

            var createdDays = 0
            for day in manifest.specialDays where !existingDays.contains(where: { $0.id == day.id }) {
                let model = SpecialDay(
                    title: day.title,
                    date: day.date,
                    type: SpecialDayType(rawValue: day.typeRaw) ?? .custom
                )
                model.id = day.id
                model.notes = day.notes
                model.repeatsYearly = day.repeatsYearly
                model.reminderDays = day.reminderDays
                model.reminderTimeHour = day.reminderTimeHour
                model.reminderTimeMinute = day.reminderTimeMinute
                model.createdAt = day.createdAt
                context.insert(model)
                createdDays += 1
            }

            var createdReminders = 0
            let existingReminderIDs = Set(existingReminders.map(\.id))
            for reminder in manifest.reminders where !existingReminderIDs.contains(reminder.id) {
                let model = ReminderConfiguration(specialDayID: reminder.specialDayID, daysBefore: reminder.daysBefore)
                model.id = reminder.id
                model.timeHour = reminder.timeHour
                model.timeMinute = reminder.timeMinute
                model.isEnabled = reminder.isEnabled
                context.insert(model)
                createdReminders += 1
            }

            try context.save()

            // Device-independent preferences only: nothing about unlock security is
            // restored, so this device keeps its own PIN/biometric configuration.
            applyRestoredSettings(manifest.settings)

            var summary = Summary()
            summary.media = encrypted.count
            summary.albums = createdAlbums
            summary.specialDays = createdDays
            summary.reminders = createdReminders
            summary.skippedDuplicates = duplicateCount
            summary.bytes = encrypted.reduce(0) { $0 + $1.media.fileSize }
            written.clear()
            return await verify(summary: summary, encrypted: encrypted, progress: progress)
        } catch {
            // Roll back the transaction and remove every file written for it.
            context.rollback()
            for name in written.names { VaultStorageService.shared.delete(fileName: name) }
            if let backupError = error as? BackupError { throw backupError }
            throw BackupError.restoreFailed("The restore could not be completed, so nothing was changed. Your vault is exactly as it was.")
        }
    }

    /// Re-reads every restored item through the real decrypt path and compares it
    /// with the hash recorded in the backup — the end-to-end proof that what is now
    /// in the vault is what the backup contained.
    private func verify(
        summary: Summary,
        encrypted: [EncryptedItem],
        progress: @escaping (Progress) -> Void
    ) async -> Summary {
        progress(Progress(stage: .finished, fraction: 1, detail: "Checking the restored items"))
        let checks = encrypted.map { (fileName: $0.storedName, hash: $0.media.contentHash) }
        let outcome = await Task.detached(priority: .utility) { () -> (verified: Int, failed: Int) in
            var verified = 0
            var failed = 0
            for check in checks {
                if VaultStorageService.shared.verify(fileName: check.fileName, matchesPlaintextHash: check.hash) {
                    verified += 1
                } else {
                    failed += 1
                }
            }
            return (verified, failed)
        }.value
        var result = summary
        result.verified = outcome.verified
        result.failedVerification = outcome.failed
        return result
    }

    private func applyRestoredSettings(_ settings: BackupManifest.Settings) {
        let defaults = UserDefaults.standard
        if let autoLock = settings.autoLockSeconds { defaults.set(autoLock, forKey: "mv.autolock") }
        if let theme = settings.themeMode { defaults.set(theme, forKey: "mv.theme") }
        if let accent = settings.accent { defaults.set(accent, forKey: "mv.accent") }
        if let columns = settings.galleryColumns { defaults.set(columns, forKey: "mv.galleryColumns") }
    }
}

/// Thread-safe cancellation flag: the heavy phases of a backup run off the main
/// actor while the button that cancels them lives on it.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}

/// Collects vault file names written during an operation so every failure path can
/// delete exactly what it created — including work that finished just before a
/// cancellation.
final class FileNameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ name: String) {
        lock.lock()
        storage.append(name)
        lock.unlock()
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}
