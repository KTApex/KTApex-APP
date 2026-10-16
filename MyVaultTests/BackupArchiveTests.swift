import XCTest
@testable import MyVault

/// Format-level tests for the `.mvbackup` container. These exercise the encrypted
/// stream directly with synthetic fixtures, so they are fast, deterministic and
/// never touch real user media.
final class BackupArchiveTests: XCTestCase {

    private var workDirectory: URL!
    private let password = "correct horse battery"

    override func setUpWithError() throws {
        continueAfterFailure = false
        workDirectory = try SecureScratch.makeDirectory(prefix: "test-archive")
    }

    override func tearDownWithError() throws {
        if let workDirectory { SecureScratch.removeDirectory(workDirectory) }
        workDirectory = nil
    }

    // MARK: - Helpers

    private func backupURL(_ name: String = "Test.mvbackup") -> URL {
        workDirectory.appendingPathComponent(name)
    }

    /// A marker that must never appear in the finished file as plaintext.
    private static let marker = "MYVAULT-PLAINTEXT-MARKER-0123456789"

    private func sampleEntries(extra: [BackupEntry] = []) -> [BackupEntry] {
        [
            BackupEntry(
                name: BackupFormat.manifestEntryName,
                source: .data(Data("{\"schemaVersion\":1,\"marker\":\"\(Self.marker)\"}".utf8)),
                compress: true
            )
        ] + extra
    }

    private func writeSample(
        to url: URL,
        extra: [BackupEntry] = [],
        password: String? = nil,
        iterations: UInt32 = BackupFormat.defaultIterations
    ) throws {
        try BackupArchive.write(
            entries: sampleEntries(extra: extra),
            password: password ?? self.password,
            to: url,
            iterations: iterations
        )
    }

    private func stagedDirectory() throws -> URL {
        try SecureScratch.makeDirectory(prefix: "staged")
    }

    private func expectFailure(
        _ body: () throws -> Void,
        equals expected: BackupError? = nil,
        _ message: String = "",
        line: UInt = #line
    ) {
        do {
            try body()
            XCTFail("Expected a failure \(message)", line: line)
        } catch let error as BackupError {
            if let expected {
                XCTAssertEqual(error, expected, message, line: line)
            }
        } catch {
            XCTFail("Expected a BackupError, got \(error)", line: line)
        }
    }

    // MARK: - Round trip

    func testEncryptionDecryptionRoundTrip() throws {
        let url = backupURL()
        let payload = Data(repeating: 0x42, count: 4096)
        try writeSample(to: url, extra: [BackupEntry(name: "media-0", source: .data(payload))])

        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }
        let result = try BackupArchive.read(from: url, password: password, into: staged)

        XCTAssertEqual(result.header.formatVersion, BackupFormat.currentVersion)
        XCTAssertEqual(result.header.iterations, BackupFormat.defaultIterations)
        XCTAssertEqual(Set(result.stagedFiles.keys), [BackupFormat.manifestEntryName, "media-0"])
        XCTAssertEqual(try Data(contentsOf: result.stagedFiles["media-0"]!), payload)
    }

    func testCompressedManifestSurvivesRoundTrip() throws {
        let url = backupURL()
        // Repetitive text compresses well; the reader must expand it back exactly.
        let repetitive = Data(String(repeating: "album-name,", count: 2000).utf8)
        try writeSample(to: url, extra: [BackupEntry(name: "media-0", source: .data(repetitive), compress: true)])

        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }
        let result = try BackupArchive.read(from: url, password: password, into: staged)
        XCTAssertEqual(try Data(contentsOf: result.stagedFiles["media-0"]!), repetitive)
    }

    func testInspectionReadsHeaderWithoutPassword() throws {
        let url = backupURL()
        try writeSample(to: url)
        let header = try BackupHeader.readHeader(from: url)
        XCTAssertEqual(header.formatVersion, BackupFormat.currentVersion)
        XCTAssertEqual(header.salt.count, BackupFormat.saltLength)
    }

    // MARK: - Password handling

    func testWrongPasswordIsRejected() throws {
        let url = backupURL()
        try writeSample(to: url)
        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }

        expectFailure({
            _ = try BackupArchive.read(from: url, password: "wrong password here", into: staged)
        }, equals: .wrongPasswordOrDamaged, "a wrong password must fail authentication")
    }

    func testWrongPasswordMessageRevealsNothing() {
        let description = BackupError.wrongPasswordOrDamaged.errorDescription ?? ""
        XCTAssertTrue(description.contains("could not be opened"))
        // The same message is used for a damaged file, so it must not single out
        // either cause as the definite reason... but it does mention both, which is
        // the most a user can be told safely.
        XCTAssertFalse(description.contains("key"))
        XCTAssertFalse(description.contains("nonce"))
        XCTAssertFalse(description.contains("PBKDF"))
    }

    // MARK: - Corruption

    func testModifiedBackupIsRejected() throws {
        let url = backupURL()
        try writeSample(to: url, extra: [BackupEntry(name: "media-0", source: .data(Data(repeating: 7, count: 2048)))])
        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }

        // Flip one byte in the middle of the payload.
        var bytes = try Data(contentsOf: url)
        let middle = bytes.count / 2
        bytes[middle] ^= 0xFF
        try bytes.write(to: url)

        expectFailure({
            _ = try BackupArchive.read(from: url, password: password, into: staged)
        }, equals: .wrongPasswordOrDamaged, "a modified payload must fail authentication")
    }

    func testTamperedHeaderIsRejected() throws {
        let url = backupURL()
        try writeSample(to: url)
        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }

        // Change the salt: the derived key changes, and the header is authenticated
        // as associated data, so this cannot silently decrypt to something else.
        var bytes = try Data(contentsOf: url)
        bytes[BackupFormat.headerFixedLength] ^= 0x01
        try bytes.write(to: url)

        expectFailure({
            _ = try BackupArchive.read(from: url, password: password, into: staged)
        }, "a tampered salt must not authenticate")
    }

    func testTruncatedBackupIsRejected() throws {
        let url = backupURL()
        try writeSample(to: url, extra: [BackupEntry(name: "media-0", source: .data(Data(repeating: 3, count: 20_000)))])
        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }

        let bytes = try Data(contentsOf: url)
        try bytes.prefix(bytes.count / 2).write(to: url)

        expectFailure({
            _ = try BackupArchive.read(from: url, password: password, into: staged)
        }, "a truncated backup must not decrypt")
    }

    func testEmptyFileIsNotABackup() throws {
        let url = backupURL("Empty.mvbackup")
        try Data().write(to: url)
        expectFailure({
            _ = try BackupHeader.readHeader(from: url)
        }, equals: .notABackupFile)
    }

    func testRandomFileIsNotABackup() throws {
        let url = backupURL("Random.bin")
        try Data(repeating: 0x11, count: 512).write(to: url)
        expectFailure({
            _ = try BackupHeader.readHeader(from: url)
        }, equals: .notABackupFile)
    }

    // MARK: - Versioning and hostile parameters

    func testUnsupportedVersionIsReportedSpecifically() throws {
        let url = backupURL("Future.mvbackup")
        var header = Data(BackupFormat.magic)
        header.append(BackupFormat.currentVersion + 1)
        header.append(BackupFormat.kdfPBKDF2SHA256)
        header.append(contentsOf: [0, 0])
        header.append(contentsOf: BackupHeader.bigEndianBytes(BackupFormat.defaultIterations))
        header.append(contentsOf: BackupHeader.bigEndianBytes(UInt16(BackupFormat.saltLength)))
        header.append(Data(repeating: 9, count: BackupFormat.saltLength))
        header.append(Data(repeating: 0, count: 64))
        try header.write(to: url)

        expectFailure({
            _ = try BackupHeader.readHeader(from: url)
        }, equals: .unsupportedVersion(Int(BackupFormat.currentVersion) + 1),
           "a newer format must say so instead of claiming corruption")
    }

    func testUnknownKeyDerivationIsRejected() throws {
        let url = backupURL("WeirdKdf.mvbackup")
        var header = Data(BackupFormat.magic)
        header.append(BackupFormat.currentVersion)
        header.append(99)
        header.append(contentsOf: [0, 0])
        header.append(contentsOf: BackupHeader.bigEndianBytes(BackupFormat.defaultIterations))
        header.append(contentsOf: BackupHeader.bigEndianBytes(UInt16(BackupFormat.saltLength)))
        header.append(Data(repeating: 9, count: BackupFormat.saltLength))
        try header.write(to: url)

        expectFailure({
            _ = try BackupHeader.readHeader(from: url)
        }, equals: .unsupportedKeyDerivation)
    }

    func testAbsurdIterationCountIsRejected() throws {
        let url = backupURL("Heavy.mvbackup")
        var header = Data(BackupFormat.magic)
        header.append(BackupFormat.currentVersion)
        header.append(BackupFormat.kdfPBKDF2SHA256)
        header.append(contentsOf: [0, 0])
        // A hostile file must not be able to spin the CPU for hours.
        header.append(contentsOf: BackupHeader.bigEndianBytes(UInt32(4_000_000_000)))
        header.append(contentsOf: BackupHeader.bigEndianBytes(UInt16(BackupFormat.saltLength)))
        header.append(Data(repeating: 9, count: BackupFormat.saltLength))
        try header.write(to: url)

        expectFailure({
            _ = try BackupHeader.readHeader(from: url)
        }, equals: .corrupted)
    }

    func testWeakIterationCountIsRejected() throws {
        let url = backupURL("Weak.mvbackup")
        var header = Data(BackupFormat.magic)
        header.append(BackupFormat.currentVersion)
        header.append(BackupFormat.kdfPBKDF2SHA256)
        header.append(contentsOf: [0, 0])
        header.append(contentsOf: BackupHeader.bigEndianBytes(UInt32(100)))
        header.append(contentsOf: BackupHeader.bigEndianBytes(UInt16(BackupFormat.saltLength)))
        header.append(Data(repeating: 9, count: BackupFormat.saltLength))
        try header.write(to: url)

        expectFailure({
            _ = try BackupHeader.readHeader(from: url)
        }, equals: .corrupted)
    }

    // MARK: - Structure and safety

    func testPlaintextNeverAppearsInTheBackupFile() throws {
        let url = backupURL()
        try writeSample(to: url, extra: [BackupEntry(name: "media-0", source: .data(Data(Self.marker.utf8)))])
        let bytes = try Data(contentsOf: url)
        let asText = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(asText.contains(Self.marker), "media must never be stored as plaintext")
        XCTAssertFalse(asText.contains("schemaVersion"), "the manifest must not be readable either")
    }

    func testEntryNameThatLooksLikeAPathIsRejected() throws {
        let url = backupURL()
        // A writer would never produce this, so the reader must treat it as hostile.
        try BackupArchive.write(
            entries: [BackupEntry(name: "../escape", source: .data(Data("x".utf8)))],
            password: password,
            to: url
        )
        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }
        expectFailure({
            _ = try BackupArchive.read(from: url, password: password, into: staged)
        }, equals: .corrupted)
    }

    func testStagedFilesAreNeverNamedAfterTheirEntries() throws {
        let url = backupURL()
        try writeSample(to: url, extra: [BackupEntry(name: "media-0", source: .data(Data("payload".utf8)))])
        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }
        _ = try BackupArchive.read(from: url, password: password, into: staged)

        let stagedNames = try FileManager.default.contentsOfDirectory(atPath: staged.path)
        XCTAssertFalse(stagedNames.contains("media-0"), "staged files must use generated names")
        XCTAssertTrue(stagedNames.contains("entry-1"))
    }

    func testLargeEntryIsSplitIntoSeveralParts() throws {
        let url = backupURL()
        // Three parts' worth: bigger than one 4 MiB part, small enough to stay quick.
        let size = BackupFormat.partSize * 3 + 1234
        let payload = Data((0..<size).map { UInt8($0 % 251) })
        let fileURL = workDirectory.appendingPathComponent("large.bin")
        try payload.write(to: fileURL)

        try writeSample(to: url, extra: [BackupEntry(name: "media-0", source: .file(fileURL, byteCount: payload.count))])
        let staged = try stagedDirectory()
        defer { SecureScratch.removeDirectory(staged) }
        let result = try BackupArchive.read(from: url, password: password, into: staged)

        let restored = try Data(contentsOf: result.stagedFiles["media-0"]!)
        XCTAssertEqual(restored.count, payload.count)
        XCTAssertEqual(restored, payload)
    }

    func testCancellationStopsTheWriteAndRemovesThePartialFile() throws {
        let url = backupURL("Cancelled.mvbackup")
        let payload = Data(repeating: 5, count: BackupFormat.partSize * 4)
        let fileURL = workDirectory.appendingPathComponent("cancel.bin")
        try payload.write(to: fileURL)

        expectFailure({
            _ = try BackupArchive.write(
                entries: sampleEntries(extra: [BackupEntry(name: "media-0", source: .file(fileURL, byteCount: payload.count))]),
                password: password,
                to: url,
                isCancelled: { true }
            )
        }, equals: .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a cancelled backup must not leave a file behind")
    }

    func testEmptyEntryListIsRefused() {
        let url = backupURL("None.mvbackup")
        expectFailure({
            _ = try BackupArchive.write(entries: [], password: password, to: url)
        }, equals: .failedToWrite)
    }

    func testProgressReportsRealBytes() throws {
        let url = backupURL()
        let payload = Data(repeating: 1, count: 8192)
        var fractions: [Double] = []
        try BackupArchive.write(
            entries: sampleEntries(extra: [BackupEntry(name: "media-0", source: .data(payload))]),
            password: password,
            to: url,
            progress: { fractions.append($0) }
        )
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.0001)
        XCTAssertTrue(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}
