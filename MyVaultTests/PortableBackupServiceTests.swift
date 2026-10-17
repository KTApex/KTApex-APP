import XCTest
import SwiftData
@testable import MyVault

/// End-to-end backup tests against real SwiftData containers and the real
/// Keychain-backed vault, using synthetic fixtures instead of user media.
final class PortableBackupServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var storedNames: [String] = []
    private var artifacts: [PortableBackupService.Artifact] = []
    private let password = "vault-backup-password-1"

    override func setUp() async throws {
        continueAfterFailure = false
        await KeychainService.shared.ensureVaultKeyExists()
        container = try Self.makeContainer()
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        for name in storedNames { VaultStorageService.shared.delete(fileName: name) }
        storedNames.removeAll()
        // Removed directly rather than through the service: `discard` is main-actor
        // isolated and tearDown is not.
        for artifact in artifacts { SecureScratch.removeDirectory(artifact.share.directory) }
        artifacts.removeAll()
        context = nil
        container = nil
    }

    private static func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            VaultAlbum.self, VaultMedia.self, SpecialDay.self,
            ReminderConfiguration.self, AppSettings.self, BackupMetadata.self
        ])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    // MARK: - Fixtures

    @discardableResult
    @MainActor
    private func seedMedia(
        _ label: String,
        isVideo: Bool = false,
        isFavorite: Bool = false,
        isInTrash: Bool = false,
        album: VaultAlbum? = nil,
        into context: ModelContext? = nil
    ) throws -> VaultMedia {
        let target = context ?? self.context!
        let payload = Data("fixture-\(label)-\(UUID().uuidString)".utf8)
        let stored = try VaultStorageService.shared.storeEncrypted(data: payload)
        storedNames.append(stored)
        let media = VaultMedia(
            fileName: "\(label).jpg",
            encryptedFileName: stored,
            mediaType: isVideo ? "video" : "photo",
            fileSize: payload.count,
            contentHash: EncryptionService.sha256(payload)
        )
        media.isFavorite = isFavorite
        media.isInTrash = isInTrash
        media.trashedAt = isInTrash ? Date().addingTimeInterval(-3600) : nil
        media.album = album
        target.insert(media)
        return media
    }

    @MainActor
    private func createBackupFromSeed() async throws -> PortableBackupService.Artifact {
        let artifact = try await PortableBackupService.shared.createBackup(
            password: password,
            context: context,
            progress: { _ in }
        )
        artifacts.append(artifact)
        return artifact
    }

    @MainActor
    private func restore(_ artifact: PortableBackupService.Artifact, into target: ModelContext, password: String? = nil) async throws -> PortableBackupService.Summary {
        try await PortableBackupService.shared.restore(
            from: artifact.url,
            password: password ?? self.password,
            context: target,
            progress: { _ in },
            cancelFlag: CancelFlag()
        )
    }

    // MARK: - Creation

    @MainActor
    func testCreateBackupProducesAVerifiableFile() async throws {
        try seedMedia("one")
        try seedMedia("two", isVideo: true)
        try context.save()

        let artifact = try await createBackupFromSeed()

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
        XCTAssertTrue(artifact.fileName.hasPrefix("MyVault_Backup_"))
        XCTAssertTrue(artifact.fileName.hasSuffix(".mvbackup"))
        XCTAssertEqual(artifact.itemCount, 2)
        XCTAssertGreaterThan(artifact.byteCount, 0)

        // The header is readable without a password, and reports the current format.
        let header = try PortableBackupService.inspect(artifact.url)
        XCTAssertEqual(header.formatVersion, BackupFormat.currentVersion)
        XCTAssertEqual(header.iterations, BackupFormat.defaultIterations)
    }

    @MainActor
    func testBackupRowsWithNoCiphertextAreReported() async throws {
        let orphan = VaultMedia(fileName: "gone.jpg", encryptedFileName: "missing-\(UUID().uuidString).mvenc", mediaType: "photo")
        context.insert(orphan)
        try seedMedia("present")
        try context.save()

        let artifact = try await createBackupFromSeed()
        XCTAssertEqual(artifact.itemCount, 1)
        XCTAssertEqual(artifact.skippedItems, 1)
    }

    // MARK: - Restore

    @MainActor
    func testRestoreRebuildsMediaAlbumsFavoritesDaysAndReminders() async throws {
        let album = VaultAlbum(name: "Summer")
        context.insert(album)
        try seedMedia("beach", isFavorite: true, album: album)
        try seedMedia("surf", isVideo: true, album: album)

        let event = SpecialDay(title: "Anniversary", date: Date(timeIntervalSince1970: 1_600_000_000), type: .anniversary)
        event.reminderDays = [7, 1]
        context.insert(event)
        let reminder = ReminderConfiguration(specialDayID: event.id, daysBefore: 3)
        context.insert(reminder)
        try context.save()

        let artifact = try await createBackupFromSeed()

        // Restore into a completely separate, empty vault.
        let freshContainer = try Self.makeContainer()
        let freshContext = ModelContext(freshContainer)
        let summary = try await restore(artifact, into: freshContext)

        XCTAssertEqual(summary.media, 2)
        XCTAssertEqual(summary.albums, 1)
        XCTAssertEqual(summary.specialDays, 1)
        XCTAssertEqual(summary.reminders, 1)
        XCTAssertEqual(summary.skippedDuplicates, 0)
        XCTAssertEqual(summary.failedVerification, 0)
        XCTAssertEqual(summary.verified, 2)

        let restoredMedia = try freshContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(restoredMedia.count, 2)
        let favorite = try XCTUnwrap(restoredMedia.first { $0.fileName == "beach.jpg" })
        XCTAssertTrue(favorite.isFavorite)
        XCTAssertEqual(favorite.album?.name, "Summer")
        XCTAssertEqual(favorite.album?.id, album.id)
        XCTAssertEqual(restoredMedia.first { $0.fileName == "surf.jpg" }?.mediaType, "video")

        // Every restored item must decrypt and match the hash recorded on backup.
        for media in restoredMedia {
            XCTAssertTrue(
                VaultStorageService.shared.verify(fileName: media.encryptedFileName, matchesPlaintextHash: media.contentHash),
                "restored \(media.fileName) must verify against the vault key"
            )
        }

        let restoredDays = try freshContext.fetch(FetchDescriptor<SpecialDay>())
        XCTAssertEqual(restoredDays.map(\.title), ["Anniversary"])
        XCTAssertEqual(restoredDays.first?.typeRaw, SpecialDayType.anniversary.rawValue)
        XCTAssertEqual(restoredDays.first?.reminderDays, [1, 7])

        let restoredReminders = try freshContext.fetch(FetchDescriptor<ReminderConfiguration>())
        XCTAssertEqual(restoredReminders.first?.daysBefore, 3)
    }

    @MainActor
    func testTrashStateSurvivesRestore() async throws {
        try seedMedia("deleted", isInTrash: true)
        try context.save()

        let artifact = try await createBackupFromSeed()
        let freshContext = ModelContext(try Self.makeContainer())
        _ = try await restore(artifact, into: freshContext)

        let restored = try freshContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(restored.first?.isInTrash, true)
        XCTAssertNotNil(restored.first?.trashedAt)
    }

    @MainActor
    func testSecondRestoreSkipsItemsAlreadyPresent() async throws {
        try seedMedia("one")
        try seedMedia("two")
        try context.save()

        let artifact = try await createBackupFromSeed()
        let freshContext = ModelContext(try Self.makeContainer())

        let first = try await restore(artifact, into: freshContext)
        XCTAssertEqual(first.media, 2)

        let second = try await restore(artifact, into: freshContext)
        XCTAssertEqual(second.media, 0)
        XCTAssertEqual(second.skippedDuplicates, 2)
        XCTAssertEqual(second.headline, "Everything in this backup is already in your vault")
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<VaultMedia>()).count, 2, "a second restore must not duplicate anything")
    }

    @MainActor
    func testRestoreAddsWithoutDisturbingExistingMedia() async throws {
        try seedMedia("backup-item")
        try context.save()
        let artifact = try await createBackupFromSeed()

        // Target vault already holds something unrelated.
        let freshContext = ModelContext(try Self.makeContainer())
        let existing = try seedMedia("already-here", into: freshContext)
        try freshContext.save()

        let summary = try await restore(artifact, into: freshContext)

        XCTAssertEqual(summary.media, 1)
        let media = try freshContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(media.count, 2)
        XCTAssertTrue(media.contains { $0.id == existing.id }, "restore must never remove what was already in the vault")
        XCTAssertTrue(
            VaultStorageService.shared.verify(fileName: existing.encryptedFileName, matchesPlaintextHash: existing.contentHash),
            "an untouched item must still be readable after a restore"
        )
    }

    // MARK: - Failure handling

    @MainActor
    func testWrongPasswordCannotPreviewOrRestore() async throws {
        try seedMedia("secret")
        try context.save()
        let artifact = try await createBackupFromSeed()

        do {
            _ = try await PortableBackupService.shared.previewRestore(from: artifact.url, password: "not-the-password")
            XCTFail("A wrong password must not produce a preview")
        } catch let error as BackupError {
            XCTAssertEqual(error, .wrongPasswordOrDamaged)
        }

        let freshContext = ModelContext(try Self.makeContainer())
        do {
            _ = try await restore(artifact, into: freshContext, password: "not-the-password")
            XCTFail("A wrong password must not restore anything")
        } catch let error as BackupError {
            XCTAssertEqual(error, .wrongPasswordOrDamaged)
        }
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<VaultMedia>()).count, 0, "a failed restore must change nothing")
    }

    @MainActor
    func testCorruptedBackupLeavesTheVaultUntouched() async throws {
        try seedMedia("keeper")
        try context.save()
        let artifact = try await createBackupFromSeed()

        var bytes = try Data(contentsOf: artifact.url)
        let middle = bytes.count / 2
        bytes[middle] ^= 0xFF
        try bytes.write(to: artifact.url)

        let freshContext = ModelContext(try Self.makeContainer())
        let before = VaultStorageService.shared.storedFileNames().count
        do {
            _ = try await restore(artifact, into: freshContext)
            XCTFail("A corrupted backup must not restore")
        } catch let error as BackupError {
            XCTAssertEqual(error, .wrongPasswordOrDamaged)
        }
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<VaultMedia>()).count, 0)
        XCTAssertEqual(VaultStorageService.shared.storedFileNames().count, before, "a failed restore must not leave orphaned ciphertext")
    }

    @MainActor
    func testCancelledRestoreChangesNothing() async throws {
        try seedMedia("one")
        try seedMedia("two")
        try context.save()
        let artifact = try await createBackupFromSeed()

        let freshContext = ModelContext(try Self.makeContainer())
        let filesBefore = VaultStorageService.shared.storedFileNames().count
        let flag = CancelFlag()
        flag.cancel()

        do {
            _ = try await PortableBackupService.shared.restore(
                from: artifact.url, password: password, context: freshContext,
                progress: { _ in }, cancelFlag: flag
            )
            XCTFail("A cancelled restore must not report success")
        } catch let error as BackupError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<VaultMedia>()).count, 0)
        XCTAssertEqual(VaultStorageService.shared.storedFileNames().count, filesBefore)
    }

    @MainActor
    func testCommitFailureRollsBackAndPreservesTheVault() async throws {
        try seedMedia("one")
        try seedMedia("two")
        try context.save()
        let artifact = try await createBackupFromSeed()

        // Target vault already holds something unrelated; a failed restore must
        // leave it exactly as it was.
        let freshContext = ModelContext(try Self.makeContainer())
        let existing = try seedMedia("already-here", into: freshContext)
        try freshContext.save()
        let filesBefore = VaultStorageService.shared.storedFileNames().count

        let service = PortableBackupService.shared
        service.forceCommitFailure = true
        defer { service.forceCommitFailure = false }
        do {
            _ = try await restore(artifact, into: freshContext)
            XCTFail("A forced commit failure must fail the restore")
        } catch let error as BackupError {
            XCTAssertEqual(error, .failedToWrite)
        }

        let remaining = try freshContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(remaining.count, 1, "the failed restore must not add any rows")
        XCTAssertTrue(remaining.contains { $0.id == existing.id }, "the pre-existing item must survive the rollback")
        XCTAssertEqual(
            VaultStorageService.shared.storedFileNames().count, filesBefore,
            "ciphertext staged in Phase A must be removed when the commit fails"
        )
        XCTAssertTrue(
            VaultStorageService.shared.verify(fileName: existing.encryptedFileName, matchesPlaintextHash: existing.contentHash),
            "the untouched item must still decrypt after the rollback"
        )
    }

    @MainActor
    func testRestoredSettingsApplyToDefaultsAndThemeManager() async throws {
        let defaults = UserDefaults.standard
        let originalTheme = defaults.string(forKey: "mv.theme")
        let originalAccent = defaults.string(forKey: "mv.accent")
        let originalColumns = defaults.object(forKey: "mv.galleryColumns") as? Int
        let originalMode = ThemeManager.shared.mode
        let originalAccentValue = ThemeManager.shared.accent
        defer {
            defaults.set(originalTheme, forKey: "mv.theme")
            defaults.set(originalAccent, forKey: "mv.accent")
            defaults.set(originalColumns, forKey: "mv.galleryColumns")
            ThemeManager.shared.mode = originalMode
            ThemeManager.shared.accent = originalAccentValue
        }

        // Back up a vault configured with non-default preferences.
        defaults.set("dark", forKey: "mv.theme")
        defaults.set("purple", forKey: "mv.accent")
        defaults.set(5, forKey: "mv.galleryColumns")
        try seedMedia("one")
        try context.save()
        let artifact = try await createBackupFromSeed()

        // Restore onto a "different device": defaults back to factory, and the
        // running manager holds the factory theme.
        defaults.set("system", forKey: "mv.theme")
        defaults.set("blue", forKey: "mv.accent")
        ThemeManager.shared.mode = .system
        ThemeManager.shared.accent = .blue

        let freshContext = ModelContext(try Self.makeContainer())
        _ = try await restore(artifact, into: freshContext)

        XCTAssertEqual(defaults.string(forKey: "mv.theme"), "dark")
        XCTAssertEqual(defaults.string(forKey: "mv.accent"), "purple")
        XCTAssertEqual(defaults.object(forKey: "mv.galleryColumns") as? Int, 5)
        XCTAssertEqual(ThemeManager.shared.mode, .dark, "the restored theme must apply to the live manager")
        XCTAssertEqual(ThemeManager.shared.accent, .purple, "the restored accent must apply to the live manager")
    }

    // MARK: - Secrets and cleanup

    @MainActor
    func testBackupPasswordIsNeverWrittenAnywhere() async throws {
        // A distinctive password so a false positive is impossible.
        let secret = "Zq7-backup-password-marker-42"
        try seedMedia("payload")
        try context.save()

        let artifact = try await PortableBackupService.shared.createBackup(
            password: secret,
            context: context,
            progress: { _ in }
        )
        artifacts.append(artifact)

        let fileText = String(decoding: try Data(contentsOf: artifact.url), as: UTF8.self)
        XCTAssertFalse(fileText.contains(secret), "the backup password must never appear in the file")

        let defaults = UserDefaults.standard.dictionaryRepresentation()
        for value in defaults.values {
            if let string = value as? String {
                XCTAssertFalse(string.contains(secret), "the backup password must never be stored in UserDefaults")
            }
        }

        // It is also not in the vault's Keychain material.
        for account in [KeychainService.Key.vaultKey, KeychainService.Key.pinVerifier, KeychainService.Key.pinSalt] {
            if let data = KeychainService.shared.get(account) {
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
            }
        }
    }

    @MainActor
    func testTemporaryPlaintextIsCleanedUp() async throws {
        try seedMedia("one")
        try context.save()
        let artifact = try await createBackupFromSeed()
        let freshContext = ModelContext(try Self.makeContainer())
        _ = try await restore(artifact, into: freshContext)

        // The artifact's own directory is still there on purpose (it is about to be
        // shared), so remove it before checking that nothing else survived.
        SecureScratch.removeDirectory(artifact.share.directory)
        artifacts.removeAll()

        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: SecureScratch.root, includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(leftovers.isEmpty, "scratch space should hold no plaintext after a restore: \(leftovers.map(\.lastPathComponent))")
    }

    // MARK: - Versioning

    func testFileThatIsNotABackupIsRejectedBeforeAnyPasswordIsAsked() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-backup-\(UUID().uuidString).mvbackup")
        try Data("definitely not a backup".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try PortableBackupService.inspect(url)) { error in
            XCTAssertEqual(error as? BackupError, .notABackupFile)
        }
    }

    func testShortBackupPasswordIsRefused() {
        XCTAssertThrowsError(try PortableBackupService.validate(password: "short", confirmation: "short")) { error in
            XCTAssertEqual(error as? BackupError, .passwordTooShort)
        }
        XCTAssertThrowsError(try PortableBackupService.validate(password: "long-enough-1", confirmation: "long-enough-2")) { error in
            XCTAssertEqual(error as? BackupError, .passwordMismatch)
        }
        XCTAssertNoThrow(try PortableBackupService.validate(password: "long-enough-1", confirmation: "long-enough-1"))
    }

    func testPasswordGuidanceRejectsShortPasswords() {
        XCTAssertFalse(BackupPasswordGuidance.assess("short").isAcceptable)
        XCTAssertTrue(BackupPasswordGuidance.assess("password1").isAcceptable)
        XCTAssertFalse(BackupPasswordGuidance.assess("password1").isStrong)
        XCTAssertTrue(BackupPasswordGuidance.assess("Password-not-1!").isStrong)
    }

    // MARK: - Truncated and empty files

    /// A file that was cut short must be rejected *before* anything is written,
    /// and the vault must be exactly as it was afterwards.
    @MainActor
    func testTruncatedBackupIsRejectedAndChangesNothing() async throws {
        try seedMedia("one")
        try seedMedia("two")
        try context.save()
        let artifact = try await createBackupFromSeed()

        // Keep the valid header (so this is still recognised as a backup) but drop
        // everything after the first few hundred bytes of ciphertext.
        let full = try Data(contentsOf: artifact.url)
        XCTAssertGreaterThan(full.count, 200)
        try full.prefix(200).write(to: artifact.url)

        let freshContext = ModelContext(try Self.makeContainer())
        let filesBefore = VaultStorageService.shared.storedFileNames().count
        do {
            _ = try await restore(artifact, into: freshContext)
            XCTFail("A truncated backup must not restore")
        } catch let error as BackupError {
            // Either authentication fails outright, or the stream ends early and the
            // reader reports the file as damaged. Both are safe and both are expected.
            XCTAssertTrue(
                error == .wrongPasswordOrDamaged || error == .corrupted,
                "expected a safe rejection, got \(error)"
            )
        }
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<VaultMedia>()).count, 0)
        XCTAssertEqual(VaultStorageService.shared.storedFileNames().count, filesBefore)
    }

    /// A header-only file is structurally a backup with no entries: it must be
    /// refused rather than treated as a valid empty restore.
    @MainActor
    func testHeaderOnlyBackupIsRejected() async throws {
        try seedMedia("one")
        try context.save()
        let artifact = try await createBackupFromSeed()

        let header = try BackupHeader.readHeader(from: artifact.url)
        try header.bytes.write(to: artifact.url)

        let freshContext = ModelContext(try Self.makeContainer())
        do {
            _ = try await restore(artifact, into: freshContext)
            XCTFail("A backup with no entries must not restore")
        } catch let error as BackupError {
            XCTAssertTrue(
                error == .corrupted || error == .wrongPasswordOrDamaged,
                "expected a safe rejection, got \(error)"
            )
        }
        XCTAssertEqual(try freshContext.fetch(FetchDescriptor<VaultMedia>()).count, 0)
    }

    /// A backup of an empty vault is refused at creation time with its own error, so
    /// the UI can say "there is nothing to back up" instead of blaming the password.
    @MainActor
    func testEmptyVaultCannotBeBackedUp() async {
        do {
            _ = try await PortableBackupService.shared.createBackup(
                password: password, context: context, progress: { _ in }
            )
            XCTFail("An empty vault must not produce a backup")
        } catch let error as BackupError {
            XCTAssertEqual(error, .nothingToBackUp)
        } catch {
            XCTFail("expected .nothingToBackUp, got \(error)")
        }
    }

    // MARK: - Versioning

    /// A file from a future format version must be rejected up front, without a
    /// password and without attempting to parse the body.
    func testUnsupportedBackupVersionIsRejected() throws {
        let header = BackupHeader(
            formatVersion: BackupFormat.currentVersion &+ 1,
            kdf: BackupFormat.kdfPBKDF2SHA256,
            iterations: BackupFormat.defaultIterations,
            salt: Data(repeating: 0x11, count: BackupFormat.saltLength)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("future-\(UUID().uuidString).mvbackup")
        defer { try? FileManager.default.removeItem(at: url) }
        try header.bytes.write(to: url)

        XCTAssertThrowsError(try PortableBackupService.inspect(url)) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedVersion(Int(header.formatVersion)))
        }

        // The reader refuses it too, so even a full restore attempt cannot proceed.
        let staging = try SecureScratch.makeDirectory(prefix: "test-version")
        defer { SecureScratch.removeDirectory(staging) }
        XCTAssertThrowsError(
            try BackupArchive.read(from: url, password: password, into: staging)
        ) { error in
            XCTAssertEqual(error as? BackupError, .unsupportedVersion(Int(header.formatVersion)))
        }
    }

    // MARK: - Scale

    /// Many items at once: every payload must round-trip, stay distinct, and verify.
    @MainActor
    func testManyItemsRestoreWithDistinctPayloads() async throws {
        let count = 40
        for index in 0..<count {
            try seedMedia("bulk-\(index)", isVideo: index.isMultiple(of: 5))
        }
        try context.save()
        let artifact = try await createBackupFromSeed()
        XCTAssertEqual(artifact.itemCount, count)

        let freshContext = ModelContext(try Self.makeContainer())
        let summary = try await restore(artifact, into: freshContext)

        XCTAssertEqual(summary.media, count)
        XCTAssertEqual(summary.verified, count)
        XCTAssertEqual(summary.failedVerification, 0)

        let restored = try freshContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(restored.count, count)
        // Each fixture payload is unique, so no two restored rows may share a hash.
        XCTAssertEqual(Set(restored.map(\.contentHash)).count, count)
        XCTAssertEqual(Set(restored.map(\.encryptedFileName)).count, count)
    }

    /// Album membership survives a restore, and items in no album stay in no album.
    @MainActor
    func testAlbumMembershipIsRestoredExactly() async throws {
        let trip = VaultAlbum(name: "Trip")
        let family = VaultAlbum(name: "Family")
        context.insert(trip)
        context.insert(family)
        try seedMedia("paris", album: trip)
        try seedMedia("rome", album: trip)
        try seedMedia("mum", album: family)
        try seedMedia("loose")
        try context.save()

        let artifact = try await createBackupFromSeed()
        let freshContext = ModelContext(try Self.makeContainer())
        _ = try await restore(artifact, into: freshContext)

        let albums = try freshContext.fetch(FetchDescriptor<VaultAlbum>())
        XCTAssertEqual(albums.count, 2)
        let restoredMedia = try freshContext.fetch(FetchDescriptor<VaultMedia>())
        let membership = Dictionary(grouping: restoredMedia) { $0.album?.name ?? "none" }
        XCTAssertEqual(Set(membership["Trip"]?.map(\.fileName) ?? []), ["paris.jpg", "rome.jpg"])
        XCTAssertEqual(membership["Family"]?.map(\.fileName), ["mum.jpg"])
        XCTAssertEqual(membership["none"]?.map(\.fileName), ["loose.jpg"])
        // Album identities are reused rather than duplicated.
        XCTAssertEqual(Set(albums.map(\.id)), [trip.id, family.id])
    }

    /// Favorite state is restored per item, not as a blanket flag.
    @MainActor
    func testFavoritesAreRestoredPerItem() async throws {
        try seedMedia("loved", isFavorite: true)
        try seedMedia("plain")
        try seedMedia("loved-video", isVideo: true, isFavorite: true)
        try context.save()
        let artifact = try await createBackupFromSeed()

        let freshContext = ModelContext(try Self.makeContainer())
        _ = try await restore(artifact, into: freshContext)

        let restored = try freshContext.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(Set(restored.filter(\.isFavorite).map(\.fileName)), ["loved.jpg", "loved-video.jpg"])
        XCTAssertEqual(restored.filter { !$0.isFavorite }.map(\.fileName), ["plain.jpg"])
    }

    /// Special-day metadata (type, repeat flag, reminder offsets and times) survives.
    @MainActor
    func testSpecialDayDetailsAreRestored() async throws {
        let event = SpecialDay(title: "Mum's Birthday", date: Date(timeIntervalSince1970: 1_234_567_890), type: .birthday)
        event.notes = "Cake at 6"
        event.repeatsYearly = true
        event.reminderDays = [14, 3]
        event.reminderTimeHour = 9
        event.reminderTimeMinute = 30
        context.insert(event)
        try seedMedia("one")
        try context.save()

        let artifact = try await createBackupFromSeed()
        let freshContext = ModelContext(try Self.makeContainer())
        _ = try await restore(artifact, into: freshContext)

        let days = try freshContext.fetch(FetchDescriptor<SpecialDay>())
        let restored = try XCTUnwrap(days.first)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(restored.id, event.id)
        XCTAssertEqual(restored.title, "Mum's Birthday")
        XCTAssertEqual(restored.typeRaw, SpecialDayType.birthday.rawValue)
        XCTAssertEqual(restored.notes, "Cake at 6")
        XCTAssertTrue(restored.repeatsYearly)
        XCTAssertEqual(restored.reminderDays, [3, 14])
        XCTAssertEqual(restored.reminderTimeHour, 9)
        XCTAssertEqual(restored.reminderTimeMinute, 30)
        XCTAssertEqual(restored.date, event.date)
    }
}
