import XCTest
import UniformTypeIdentifiers
import SwiftData
@testable import MyVault

/// Tests for the boundary between Files and the app.
///
/// This is the layer that made "Import Backup" fail while every service-level test
/// passed: unit tests hand the service a URL this app owns, whereas the document
/// picker hands back a URL belonging to another process. These tests cover the parts
/// that can be exercised without a real picker — the type declaration the picker
/// filters on, and the staging copy that stands between the provider and the
/// restore engine.
final class BackupFileImporterTests: XCTestCase {

    private var stagingDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in stagingDirectories { SecureScratch.removeDirectory(directory) }
        stagingDirectories.removeAll()
    }

    private func stage(_ url: URL) throws -> BackupFileImporter.Staged {
        let staged = try BackupFileImporter.stageCopy(of: url)
        stagingDirectories.append(staged.directory)
        return staged
    }

    // MARK: - Type declaration

    /// The picker filters on these types. If the exported declaration in Info.plist
    /// and this constant ever disagree, the app exports one type and accepts another,
    /// which is exactly the state that made the backup unselectable in Files.
    func testExportedTypeIdentifierMatchesThePlist() throws {
        XCTAssertEqual(MyVaultBackupType.identifier, "com.ktapex.myvault.backup")
        XCTAssertEqual(MyVaultBackupType.fileExtension, "mvbackup")

        // The app's Info.plist, not the test bundle's: the declaration that matters is
        // the one iOS reads for the installed app.
        let appBundle = Bundle(for: PortableBackupService.self)
        let plist = try XCTUnwrap(appBundle.infoDictionary)
        let declared = try XCTUnwrap(
            plist["UTExportedTypeDeclarations"] as? [[String: Any]],
            "Info.plist must export a type for .mvbackup"
        )
        let identifiers = declared.compactMap { $0["UTTypeIdentifier"] as? String }
        XCTAssertTrue(
            identifiers.contains(MyVaultBackupType.identifier),
            "the exported type must use the same identifier the app accepts: \(identifiers)"
        )
        let tags = declared.compactMap { $0["UTTypeTagSpecification"] as? [String: Any] }
        let extensions = tags.compactMap { $0["public.filename-extension"] as? [String] }.flatMap { $0 }
        XCTAssertTrue(
            extensions.contains(MyVaultBackupType.fileExtension),
            "the exported type must claim the mvbackup extension, found: \(extensions)"
        )
    }

    /// The declaration that actually makes Files hand the file to MyVault.
    ///
    /// A correct UTI is not sufficient on its own: without
    /// `LSSupportsOpeningDocumentsInPlace` the system treats the app as non-document, so
    /// iOS never offers it and never delivers the URL — which is exactly the reported
    /// symptom of Copy / Share / Quick Look appearing but MyVault not being an option.
    /// This test exists so the key cannot be dropped again.
    func testDocumentOpeningInPlaceIsDeclared() throws {
        let plist = try XCTUnwrap(Bundle(for: PortableBackupService.self).infoDictionary)
        XCTAssertEqual(
            plist["LSSupportsOpeningDocumentsInPlace"] as? Bool,
            true,
            "without LSSupportsOpeningDocumentsInPlace iOS will not hand .mvbackup to MyVault"
        )
    }

    /// The document-type entry must claim the app's own UTI and use a role appropriate
    /// to a format the app both reads and writes. `Viewer` describes an app that only
    /// displays a type, which is wrong for an owned, read-write format.
    func testDocumentTypeClaimsTheBackupTypeAsEditor() throws {
        let plist = try XCTUnwrap(Bundle(for: PortableBackupService.self).infoDictionary)
        let types = try XCTUnwrap(
            plist["CFBundleDocumentTypes"] as? [[String: Any]],
            "CFBundleDocumentTypes must be declared"
        )
        let backupEntry = try XCTUnwrap(
            types.first { entry in
                let contents = entry["LSItemContentTypes"] as? [String] ?? []
                return contents.contains(MyVaultBackupType.identifier)
            },
            "no CFBundleDocumentTypes entry claims \(MyVaultBackupType.identifier)"
        )
        XCTAssertEqual(backupEntry["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(backupEntry["LSHandlerRank"] as? String, "Owner")
    }

    /// The exported type's parent must match what the Swift type declares, or the
    /// system and the app disagree about whether the file is data.
    func testExportedTypeConformsToDataInBothPlaces() throws {
        let plist = try XCTUnwrap(Bundle(for: PortableBackupService.self).infoDictionary)
        let declared = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let conforms = declared
            .compactMap { $0["UTTypeConformsTo"] as? [String] }
            .flatMap { $0 }
        XCTAssertTrue(conforms.contains("public.data"), "plist must declare public.data conformance")
        XCTAssertTrue(UTType.myVaultBackup.conforms(to: .data), "Swift type must conform to .data too")
    }

    /// The app's own type must be offered to the picker, with `.data` only as a
    /// fallback for a backup whose extension was lost in transit.
    func testImporterAcceptsTheBackupTypeAndPlainData() {
        XCTAssertEqual(MyVaultBackupType.importableTypes.first, .myVaultBackup)
        XCTAssertTrue(MyVaultBackupType.importableTypes.contains(.data))
    }

    func testExportedTypeConformsToDataSoTheSystemStillSeesItAsAFile() {
        XCTAssertTrue(UTType.myVaultBackup.conforms(to: .data))
    }

    // MARK: - Extension detection

    func testExtensionIsRecognisedRegardlessOfCase() {
        XCTAssertTrue(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/MyVault_Backup.mvbackup")))
        XCTAssertTrue(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/MyVault_Backup.MVBACKUP")))
        XCTAssertFalse(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/photo.jpg")))
        XCTAssertFalse(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/backup.mvbackup.txt")))
    }

    // MARK: - Staging the picked file

    /// The picked file must arrive byte-for-byte. Any transformation here would break
    /// decryption, because the format is an exact byte stream.
    func testStagingCopiesTheFileUnchanged() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyVault_Backup_\(UUID().uuidString).mvbackup")
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try stage(source)

        XCTAssertEqual(try Data(contentsOf: staged.url), bytes)
        XCTAssertEqual(staged.originalName, source.lastPathComponent)
        XCTAssertFalse(staged.extensionUnexpected)
        // The staged copy lives under a name this app controls, not the picked one,
        // so a hostile file name never reaches the file system.
        XCTAssertEqual(staged.url.lastPathComponent, "incoming.mvbackup")
    }

    /// A backup that arrived without the extension — renamed by a provider, or saved
    /// from a chat app — is still importable, but the user is told.
    func testStagingFlagsAnUnexpectedExtensionWithoutRejectingIt() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyVault_Backup_\(UUID().uuidString).dat")
        try Data("MVBK".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try stage(source)

        XCTAssertTrue(staged.extensionUnexpected)
        XCTAssertEqual(staged.url.lastPathComponent, "incoming.mvbackup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.url.path))
    }

    /// A missing file must be reported, not silently produce an empty staged file.
    func testStagingAMissingFileFails() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString).mvbackup")
        XCTAssertThrowsError(try BackupFileImporter.stageCopy(of: missing)) { error in
            guard case BackupFileImporter.ImportError.failed = error else {
                return XCTFail("expected a reported failure, got \(error)")
            }
        }
    }

    /// Discarding must remove the whole directory, so no copy of a backup is left in
    /// temporary storage after the user finishes.
    func testDiscardRemovesTheStagedDirectory() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyVault_Backup_\(UUID().uuidString).mvbackup")
        try Data("MVBK".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let staged = try stage(source)
        let directory = staged.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        staged.discard()
        stagingDirectories.removeAll { $0 == directory }

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - External document opening (Files tap → MyVault)

    /// Only a `.mvbackup` may reach the importer. Anything else the system might hand
    /// over — a stray URL, a photo, a text file — is refused before it is parsed.
    func testOnlyBackupExtensionsAreAcceptedFromOutsideTheApp() {
        XCTAssertTrue(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/MyVault_Backup_2026-10-17_10-00.mvbackup")))
        XCTAssertFalse(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertFalse(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/photo.jpg")))
        XCTAssertFalse(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/MyVault_Backup.mvbackup.bak")))
        XCTAssertFalse(MyVaultBackupType.looksLikeBackup(URL(fileURLWithPath: "/tmp/noextension")))
    }

    /// The routing seam used by both the AppDelegate and `onOpenURL`: staging an
    /// external file must produce a usable local copy, and a non-backup must be
    /// refused. This is the logic the real-device flow depends on.
    @MainActor
    func testOpenBackupDocumentStagesAValidFileAndRefusesOthers() throws {
        let state = AppState()

        let valid = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyVault_Backup_\(UUID().uuidString).mvbackup")
        try Data("MVBK".utf8).write(to: valid)
        defer { try? FileManager.default.removeItem(at: valid) }

        state.openBackupDocument(at: valid)
        let pending = try XCTUnwrap(state.pendingBackupOpen, "a valid .mvbackup must be staged")
        XCTAssertEqual(pending.displayName, valid.lastPathComponent)
        XCTAssertEqual(pending.url.lastPathComponent, "incoming.mvbackup")
        XCTAssertEqual(try Data(contentsOf: pending.url), Data("MVBK".utf8))

        // The scratch copy is removed when the request is dismissed, so no backup is
        // left behind after the user finishes.
        let directory = pending.directory
        state.clearPendingBackupOpen()
        XCTAssertNil(state.pendingBackupOpen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        // A missing file is reported, and nothing is left pending.
        state.openBackupDocument(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).mvbackup"))
        XCTAssertNil(state.pendingBackupOpen)
        XCTAssertNotNil(state.documentOpenError, "a failed open must tell the user")
        state.documentOpenError = nil
    }

    /// A parked request must not be presented while the vault is locked: the UI layer
    /// gates on `isUnlocked`, and a document open never decrypts before authentication.
    @MainActor
    func testADocumentOpenIsNotConsumedWhileLocked() throws {
        let state = AppState()
        state.isUnlocked = false

        let valid = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyVault_Backup_\(UUID().uuidString).mvbackup")
        try Data("MVBK".utf8).write(to: valid)
        defer { try? FileManager.default.removeItem(at: valid) }

        state.openBackupDocument(at: valid)

        // Staged, but still parked: the vault is locked.
        XCTAssertNotNil(state.pendingBackupOpen)
        XCTAssertFalse(state.isUnlocked)

        // Once unlocked, the same parked request becomes presentable.
        state.isUnlocked = true
        XCTAssertNotNil(state.pendingBackupOpen)
        state.clearPendingBackupOpen()
        XCTAssertNil(state.pendingBackupOpen)
    }

    // MARK: - End to end across the boundary

    /// The whole point of this file: a real backup, copied in exactly the way the
    /// picker delivers it, must still validate, preview and restore. Service-level
    /// tests pass a URL this app owns, so they never exercise this path.
    @MainActor
    func testAStagedBackupStillValidatesAndRestores() async throws {
        await KeychainService.shared.ensureVaultKeyExists()
        let schema = Schema([
            VaultAlbum.self, VaultMedia.self, SpecialDay.self,
            ReminderConfiguration.self, AppSettings.self, BackupMetadata.self
        ])
        func makeContext() throws -> ModelContext {
            let container = try ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            ])
            return ModelContext(container)
        }

        let source = try makeContext()
        let payload = Data("boundary-fixture-\(UUID().uuidString)".utf8)
        let stored = try VaultStorageService.shared.storeEncrypted(data: payload)
        defer { VaultStorageService.shared.delete(fileName: stored) }
        let media = VaultMedia(
            fileName: "one.jpg", encryptedFileName: stored, mediaType: "photo",
            fileSize: payload.count, contentHash: EncryptionService.sha256(payload)
        )
        source.insert(media)
        try source.save()

        let password = "boundary-password-1"
        let artifact = try await PortableBackupService.shared.createBackup(
            password: password, context: source, progress: { _ in }
        )
        defer { SecureScratch.removeDirectory(artifact.share.directory) }

        // Simulate Files: the backup exists outside the app, then is picked and staged.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("FromFiles_\(UUID().uuidString).mvbackup")
        try Data(contentsOf: artifact.url).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let staged = try stage(outside)
        // Header validation decides whether the password is asked for at all.
        XCTAssertEqual(try PortableBackupService.inspect(staged.url).formatVersion, BackupFormat.currentVersion)

        let preview = try await PortableBackupService.shared.previewRestore(from: staged.url, password: password)
        XCTAssertEqual(preview.formatVersion, Int(BackupFormat.currentVersion))

        let target = try makeContext()
        let summary = try await PortableBackupService.shared.restore(
            from: staged.url, password: password, context: target,
            progress: { _ in }, cancelFlag: CancelFlag()
        )

        XCTAssertEqual(summary.media, 1)
        XCTAssertEqual(summary.verified, 1, "the restored copy must decrypt through the real vault key")
        XCTAssertEqual(summary.failedVerification, 0)

        let restored = try XCTUnwrap(try target.fetch(FetchDescriptor<VaultMedia>()).first)
        XCTAssertTrue(
            VaultStorageService.shared.verify(fileName: restored.encryptedFileName, matchesPlaintextHash: restored.contentHash),
            "a backup that crossed the picker boundary must still decrypt"
        )
    }
}