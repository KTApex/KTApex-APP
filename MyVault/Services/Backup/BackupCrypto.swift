import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Cryptography for the portable backup format.
///
/// Only two primitives are used, both Apple-provided and neither invented here:
///
/// * **PBKDF2-HMAC-SHA256** (CommonCrypto's `CCKeyDerivationPBKDF`) turns the
///   user's backup password into a 256-bit key. PBKDF2 with a per-backup random
///   salt and a high iteration count is the reviewed, standard way to make offline
///   guessing of a human-chosen password expensive. CryptoKit has no password-based
///   KDF, so this stays with Apple's own implementation rather than a third-party
///   package.
/// * **AES-GCM** (CryptoKit) encrypts each 4 MiB part with a fresh random 96-bit
///   nonce and a 128-bit authentication tag. The vault's own file encryption uses
///   the same authenticated cipher, so there is one encryption story in the app.
///
/// Every part is bound to the file header and to its own (entry, part) position
/// through AES-GCM associated data, so a modified header, a reordered part, or a
/// duplicated part cannot authenticate.
enum BackupCrypto {

    static let keyLength = 32
    static let saltLength = BackupFormat.saltLength

    /// Cryptographically secure random bytes from the system RNG.
    static func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw BackupError.failedToWrite }
        return Data(bytes)
    }

    // MARK: - Password → key

    static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        guard iterations >= BackupFormat.minimumIterations,
              iterations <= BackupFormat.maximumIterations else {
            throw BackupError.corrupted
        }
        guard salt.count >= BackupFormat.minimumSaltLength else { throw BackupError.corrupted }

        // Normalised so the same typed password derives the same key on any device
        // regardless of how the text was entered.
        let passwordBytes = Array(password.precomposedStringWithCanonicalMapping.utf8)
        guard !passwordBytes.isEmpty else { throw BackupError.passwordTooShort }

        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = passwordBytes.withUnsafeBufferPointer { passwordBuffer -> Int32 in
            salt.withUnsafeBytes { saltBuffer -> Int32 in
                derived.withUnsafeMutableBufferPointer { output -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress,
                        passwordBytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        output.baseAddress,
                        derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw BackupError.corrupted }
        let key = SymmetricKey(data: Data(derived))
        for index in derived.indices { derived[index] = 0 }
        return key
    }

    // MARK: - Part sealing

    /// Binds a part to the header and to its position in the stream.
    static func associatedData(header: Data, entryIndex: UInt32, partIndex: UInt32) -> Data {
        var data = header
        data.append(contentsOf: BackupHeader.bigEndianBytes(entryIndex))
        data.append(contentsOf: BackupHeader.bigEndianBytes(partIndex))
        return data
    }

    /// Encrypts one part with a fresh random 96-bit nonce.
    static func seal(_ plaintext: Data, key: SymmetricKey, associatedData: Data) throws -> Data {
        do {
            let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
            guard let combined = box.combined else { throw BackupError.failedToWrite }
            return combined
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.failedToWrite
        }
    }

    /// Decrypts one part. Any authentication failure collapses into a single
    /// "wrong password or damaged" error so the two cases are indistinguishable.
    static func open(_ sealed: Data, key: SymmetricKey, associatedData: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch {
            throw BackupError.wrongPasswordOrDamaged
        }
    }

    // MARK: - File hashing

    /// SHA-256 of a file, streamed so a multi-gigabyte video is never loaded.
    static func fileDigest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
