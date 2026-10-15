import XCTest
@testable import MyVault

/// Storage integration tests that exercise the real Encrypt → Disk → Decrypt path
/// against the actual Keychain-backed vault key. Require a simulator/device host
/// (pure unit-test hosts may lack a real Keychain).
final class VaultStorageIntegrationTests: XCTestCase {

    private var storedNames: [String] = []

    override func setUp() async throws {
        continueAfterFailure = false
        await KeychainService.shared.ensureVaultKeyExists()
    }

    override func tearDownWithError() throws {
        for name in storedNames {
            VaultStorageService.shared.delete(fileName: name)
        }
        storedNames.removeAll()
    }

    func testEncryptedFileIsNotPlaintextOnDisk() throws {
        let plaintext = Data("photo-bytes".utf8)
        let name = try VaultStorageService.shared.storeEncrypted(data: plaintext)
        storedNames.append(name)

        let url = VaultStorageService.shared.vaultDirectory.appendingPathComponent(name)
        let onDisk = try Data(contentsOf: url)
        XCTAssertNotEqual(onDisk, plaintext, "Vault file must be ciphertext, not plaintext")
    }

    func testEncryptDecryptRoundTripThroughDisk() throws {
        let plaintext = Data("roundtrip".utf8)
        let name = try VaultStorageService.shared.storeEncrypted(data: plaintext)
        storedNames.append(name)
        let recovered = try VaultStorageService.shared.loadDecrypted(fileName: name)
        XCTAssertEqual(recovered, plaintext)
    }

    func testCorruptedVaultFileRejected() throws {
        let name = try VaultStorageService.shared.storeEncrypted(data: Data("integrity".utf8))
        storedNames.append(name)

        let url = VaultStorageService.shared.vaultDirectory.appendingPathComponent(name)
        var corrupted = try Data(contentsOf: url)
        let mid = corrupted.count / 2
        corrupted[mid] ^= 0xFF
        try corrupted.write(to: url, options: .atomic)

        // Decryption must throw and never return plaintext.
        XCTAssertThrowsError(try VaultStorageService.shared.loadDecrypted(fileName: name))
    }
}
