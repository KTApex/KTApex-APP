import XCTest
import UIKit
@testable import MyVault

/// Exercises the real import path — sniff → encrypt → write → read back → verify —
/// against the actual Keychain-backed vault key, using synthetic fixtures instead
/// of real user media.
final class VaultImportServiceTests: XCTestCase {

    private var storedNames: [String] = []

    override func setUp() async throws {
        continueAfterFailure = false
        await KeychainService.shared.ensureVaultKeyExists()
    }

    override func tearDownWithError() throws {
        for name in storedNames { VaultStorageService.shared.delete(fileName: name) }
        storedNames.removeAll()
    }

    // MARK: - Fixtures

    private func jpegData(width: Int = 12, height: Int = 6) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    /// A container header with no tracks behind it: exactly what a truncated
    /// download looks like.
    private func headerOnlyVideo() -> Data {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x20]
        bytes.append(contentsOf: Array("ftyp".utf8))
        bytes.append(contentsOf: Array("isom".utf8))
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08])
        return Data(bytes)
    }

    private func payload(_ data: Data, name: String? = nil, capturedAt: Date? = nil, asset: String? = "asset-1") -> ImportPayload {
        ImportPayload(data: data, assetIdentifier: asset, suggestedFileName: name, capturedAt: capturedAt)
    }

    private func importOne(_ payload: ImportPayload, seen: Set<String> = []) async -> ImportItemResult {
        let result = await VaultImportService.shared.importItem(payload, seenHashes: seen)
        if !result.storedName.isEmpty { storedNames.append(result.storedName) }
        return result
    }

    // MARK: - Happy path

    func testImportStoresAVerifiedEncryptedCopy() async throws {
        let data = try jpegData()
        let result = await importOne(payload(data, name: "IMG_0001.HEIC"))

        XCTAssertEqual(result.status, .imported)
        XCTAssertFalse(result.storedName.isEmpty)
        XCTAssertEqual(result.mediaType, "photo")
        XCTAssertEqual(result.fileSize, data.count)
        XCTAssertEqual(result.width, 12)
        XCTAssertEqual(result.height, 6)
        XCTAssertEqual(result.fileName, "IMG_0001.jpg")

        // The vault copy must verify through the real decrypt path…
        XCTAssertTrue(VaultStorageService.shared.verify(fileName: result.storedName, matchesPlaintextHash: result.contentHash))

        // …and the bytes on disk must not be the plaintext.
        let url = VaultStorageService.shared.vaultDirectory.appendingPathComponent(result.storedName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotEqual(try Data(contentsOf: url), data)
    }

    func testCaptureDateAndAssetIdentifierAreCarriedThrough() async throws {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let result = await importOne(payload(try jpegData(), capturedAt: captured, asset: "asset-42"))

        XCTAssertEqual(result.status, .imported)
        XCTAssertEqual(result.assetIdentifier, "asset-42")
        XCTAssertEqual(result.capturedAt, captured)
    }

    // MARK: - Duplicates

    func testSecondImportOfIdenticalBytesIsADuplicate() async throws {
        let data = try jpegData()
        let first = await importOne(payload(data))
        XCTAssertEqual(first.status, .imported)

        let before = VaultStorageService.shared.storedFileNames().count
        let second = await importOne(payload(data), seen: [first.contentHash])

        XCTAssertEqual(second.status, .duplicate)
        XCTAssertTrue(second.storedName.isEmpty)
        XCTAssertEqual(VaultStorageService.shared.storedFileNames().count, before)
    }

    func testBatchDedupesIdenticalItemsWithinOneRun() async throws {
        let data = try jpegData()
        let outcome = await VaultImportService.shared.importBatch(
            [payload(data), payload(data)],
            existingHashes: []
        )
        for result in outcome.results where !result.storedName.isEmpty { storedNames.append(result.storedName) }

        XCTAssertEqual(outcome.importedCount, 1)
        XCTAssertEqual(outcome.duplicateCount, 1)
        XCTAssertEqual(outcome.failedCount, 0)
    }

    // MARK: - Rejections

    func testCorruptBytesAreRejectedAndNothingIsStored() async {
        let before = VaultStorageService.shared.storedFileNames().count
        let result = await importOne(payload(Data(repeating: 0x5A, count: 4096)))

        XCTAssertEqual(result.status, .failed)
        XCTAssertNotNil(result.errorMessage)
        XCTAssertTrue(result.storedName.isEmpty)
        XCTAssertEqual(VaultStorageService.shared.storedFileNames().count, before)
    }

    func testEmptyItemIsRejected() async {
        let result = await importOne(payload(Data()))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.storedName.isEmpty)
    }

    func testVideoContainerWithoutTracksIsRejected() async {
        let result = await importOne(payload(headerOnlyVideo(), name: "clip.mp4"))
        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.storedName.isEmpty)
    }

    // MARK: - Naming and verification

    func testSuggestedPhotoNameIsSanitised() async throws {
        let result = await importOne(payload(try jpegData(), name: "holiday/2026:beach.heic"))
        XCTAssertEqual(result.status, .imported)
        XCTAssertFalse(result.fileName.contains("/"))
        XCTAssertFalse(result.fileName.contains(":"))
        XCTAssertTrue(result.fileName.hasSuffix(".jpg"))
    }

    func testVerificationFailsForAMismatchedHash() async throws {
        let result = await importOne(payload(try jpegData()))
        XCTAssertEqual(result.status, .imported)
        XCTAssertFalse(VaultStorageService.shared.verify(fileName: result.storedName, matchesPlaintextHash: "deadbeef"))
        XCTAssertFalse(VaultStorageService.shared.verify(fileName: "does-not-exist.mvenc", matchesPlaintextHash: result.contentHash))
    }

    func testStoredFileSizeIsReported() async throws {
        let result = await importOne(payload(try jpegData()))
        XCTAssertEqual(result.status, .imported)
        let size = VaultStorageService.shared.storedFileSize(fileName: result.storedName)
        // AES-GCM adds a 12-byte nonce and a 16-byte tag.
        XCTAssertEqual(size, result.fileSize + 28)
    }
}
