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
}
