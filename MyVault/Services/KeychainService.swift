import Foundation
import Security

/// Secure key storage. Never stores PINs raw; stores vault key + PIN verifier.
final class KeychainService {
    static let shared = KeychainService()
    private let service = "com.myvault.keys"
    private init() {}

    enum Key {
        static let vaultKey = "mv.vaultKey"
        static let pinVerifier = "mv.pinVerifier"
        static let pinSalt = "mv.pinSalt"
    }

    @discardableResult
    func set(_ data: Data, for account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecService as String: service,
            kSecAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func get(_ account: String) -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecService as String: service,
            kSecAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func delete(_ account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecService as String: service,
            kSecAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }

    func ensureVaultKeyExists() async {
        if get(Key.vaultKey) == nil {
            // 32-byte (256-bit) key from the OS CSPRNG.
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { return } // retried on next launch
            set(Data(bytes), for: Key.vaultKey)
        }
    }

    func vaultKey() throws -> Data {
        if let d = get(Key.vaultKey) { return d }
        throw VaultError.keyMissing
    }
}

enum VaultError: Error {
    case keyMissing
    case encryptionFailed
    case decryptionFailed
    case ioError
    case corrupted
}
