import Foundation
import CryptoKit

/// AES-GCM file encryption. Key lives in Keychain, never in SwiftData.
final class EncryptionService {
    static let shared = EncryptionService()
    private init() {}

    func encrypt(_ plaintext: Data) throws -> Data {
        let keyData = try KeychainService.shared.vaultKey()
        let key = SymmetricKey(data: keyData)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw VaultError.encryptionFailed }
            return combined
        } catch {
            throw VaultError.encryptionFailed
        }
    }

    func decrypt(_ combined: Data) throws -> Data {
        let keyData = try KeychainService.shared.vaultKey()
        let key = SymmetricKey(data: keyData)
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.decryptionFailed
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
