import XCTest
import CryptoKit
@testable import MyVault

final class EncryptionTests: XCTestCase {
    func testEncryptDecryptRoundTrip() throws {
        let data = Data("hello vault".utf8)
        // Exercise AES-GCM directly so the test runs without Keychain access.
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(data, using: key)
        let opened = try AES.GCM.open(sealed, using: key)
        XCTAssertEqual(opened, data)
    }

    func testCiphertextDiffersFromPlaintext() throws {
        let data = Data("sensitive photo bytes".utf8)
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(data, using: key)
        XCTAssertNotEqual(sealed.combined, data)
    }

    func testWrongKeyFailsDecryption() throws {
        let data = Data("secret".utf8)
        let k1 = SymmetricKey(size: .bits256)
        let k2 = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(data, using: k1)
        XCTAssertThrowsError(try AES.GCM.open(sealed, using: k2))
    }

    func testSHA256Deterministic() {
        let a = EncryptionService.sha256(Data("abc".utf8))
        let b = EncryptionService.sha256(Data("abc".utf8))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertNotEqual(a, EncryptionService.sha256(Data("abd".utf8)))
    }

    func testTamperedCiphertextRejected() throws {
        // Flip a byte in the middle of the ciphertext; AES-GCM must reject it.
        let data = Data("integrity check".utf8)
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(data, using: key)
        var tampered = sealed.combined!
        let mid = tampered.count / 2
        tampered[mid] ^= 0xFF
        let box = try AES.GCM.SealedBox(combined: tampered)
        XCTAssertThrowsError(try AES.GCM.open(box, using: key))
    }

    func testTruncatedCiphertextRejected() throws {
        let data = Data("truncation".utf8)
        let key = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(data, using: key)
        // Drop the trailing 16-byte authentication tag. The combined box is still
        // long enough to construct, so the failure surfaces at `open` (tag check).
        let truncated = sealed.combined!.dropLast(16)
        let box = try AES.GCM.SealedBox(combined: Data(truncated))
        XCTAssertThrowsError(try AES.GCM.open(box, using: key))
    }
}
