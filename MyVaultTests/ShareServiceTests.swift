import XCTest
import UIKit
@testable import MyVault

/// The share path must hand another app a file it can actually open, and must not
/// leave decrypted media behind. Both properties are checked against the real
/// encrypt → share → cleanup path.
final class ShareServiceTests: XCTestCase {

    private var storedNames: [String] = []
    private var scratchDirectories: [URL] = []

    override func setUp() async throws {
        continueAfterFailure = false
        await KeychainService.shared.ensureVaultKeyExists()
    }

    override func tearDown() async throws {
        for name in storedNames { VaultStorageService.shared.delete(fileName: name) }
        storedNames.removeAll()
        for directory in scratchDirectories { SecureScratch.removeDirectory(directory) }
        scratchDirectories.removeAll()
    }

    // MARK: - Fixtures

    private func jpegData(width: Int = 10, height: Int = 10) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    private func makeMedia(_ data: Data, name: String, type: String = "photo") throws -> VaultMedia {
        let stored = try VaultStorageService.shared.storeEncrypted(data: data)
        storedNames.append(stored)
        return VaultMedia(
            fileName: name,
            encryptedFileName: stored,
            mediaType: type,
            fileSize: data.count,
            contentHash: EncryptionService.sha256(data)
        )
    }

    @MainActor
    private func prepare(_ items: [VaultMedia]) async throws -> ShareService.Prepared {
        let prepared = try await ShareService.shared.prepare(items)
        scratchDirectories.append(prepared.directory)
        return prepared
    }

    // MARK: - Tests

    @MainActor
    func testExportIsUsableMediaWithTheSniffedExtension() async throws {
        let plaintext = try jpegData()
        let media = try makeMedia(plaintext, name: "IMG_1234.heic")

        let prepared = try await prepare([media])

        XCTAssertEqual(prepared.urls.count, 1)
        XCTAssertTrue(prepared.skipped.isEmpty)
        let url = try XCTUnwrap(prepared.urls.first)
        XCTAssertEqual(url.pathExtension, "jpg", "the recipient must receive a real image extension")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertEqual(try Data(contentsOf: url), plaintext, "recipient must receive the decrypted media, not ciphertext")
    }

    @MainActor
    func testPreparedExportIsNotTheVaultCiphertext() async throws {
        let plaintext = try jpegData()
        let media = try makeMedia(plaintext, name: "photo")

        let prepared = try await prepare([media])
        let exported = try Data(contentsOf: try XCTUnwrap(prepared.urls.first))
        let ciphertext = try Data(contentsOf: VaultStorageService.shared.vaultDirectory
            .appendingPathComponent(media.encryptedFileName))

        XCTAssertNotEqual(exported, ciphertext)
        XCTAssertEqual(exported, plaintext)
    }

    @MainActor
    func testCleanupRemovesEveryExportedFile() async throws {
        let media = try makeMedia(try jpegData(), name: "one")
        let prepared = try await prepare([media])
        let directory = prepared.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        ShareService.shared.cleanup(prepared)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        scratchDirectories.removeAll { $0 == directory }
    }

    @MainActor
    func testEmptySelectionIsRejected() async {
        do {
            _ = try await ShareService.shared.prepare([])
            XCTFail("Preparing an empty selection must fail")
        } catch {
            XCTAssertEqual(error as? ShareService.ShareError, .nothingSelected)
        }
    }

    @MainActor
    func testUnreadableItemIsReportedInsteadOfShared() async throws {
        let good = try makeMedia(try jpegData(), name: "good")
        let missing = VaultMedia(fileName: "gone", encryptedFileName: "definitely-not-there.mvenc", mediaType: "photo")

        let prepared = try await prepare([good, missing])

        XCTAssertEqual(prepared.urls.count, 1)
        XCTAssertEqual(prepared.skipped, ["gone"])
    }

    @MainActor
    func testAllItemsUnreadableThrowsRatherThanSharingNothing() async {
        let missing = VaultMedia(fileName: "gone", encryptedFileName: "definitely-not-there.mvenc", mediaType: "photo")
        do {
            _ = try await ShareService.shared.prepare([missing])
            XCTFail("Sharing items that cannot be decrypted must fail")
        } catch {
            XCTAssertEqual(error as? ShareService.ShareError, .nothingShareable)
        }
    }

    @MainActor
    func testIdenticallyNamedItemsDoNotCollide() async throws {
        let first = try makeMedia(try jpegData(width: 8, height: 8), name: "same")
        let second = try makeMedia(try jpegData(width: 12, height: 12), name: "same")

        let prepared = try await prepare([first, second])

        XCTAssertEqual(prepared.urls.count, 2)
        XCTAssertEqual(Set(prepared.urls.map(\.lastPathComponent)).count, 2)
    }
}
