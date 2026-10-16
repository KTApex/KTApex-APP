import Foundation

/// Encrypted file storage under Application Support/vault.
final class VaultStorageService {
    static let shared = VaultStorageService()
    private let fm = FileManager.default
    private init() {}

    var vaultDirectory: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("vault", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func storeEncrypted(data: Data) throws -> String {
        let cipher = try EncryptionService.shared.encrypt(data)
        let name = UUID().uuidString + ".mvenc"
        try cipher.write(to: vaultDirectory.appendingPathComponent(name), options: .completeFileProtection)
        return name
    }

    func loadDecrypted(fileName: String) throws -> Data {
        let cipher = try Data(contentsOf: vaultDirectory.appendingPathComponent(fileName))
        return try EncryptionService.shared.decrypt(cipher)
    }

    func delete(fileName: String) {
        try? fm.removeItem(at: vaultDirectory.appendingPathComponent(fileName))
    }

    /// Re-reads a stored blob through the real decrypt path and compares it with
    /// the plaintext that was written.
    ///
    /// Returns `false` rather than throwing: a failed verification is treated
    /// by callers exactly like a failed write, and the caller must never offer to
    /// delete a Photos original for an item that does not verify.
    func verify(fileName: String, matchesPlaintextHash hash: String) -> Bool {
        guard !hash.isEmpty,
              let plaintext = try? loadDecrypted(fileName: fileName),
              !plaintext.isEmpty else { return false }
        return EncryptionService.sha256(plaintext) == hash
    }

    /// Size of the ciphertext on disk, used to confirm a write landed completely.
    func storedFileSize(fileName: String) -> Int? {
        let url = vaultDirectory.appendingPathComponent(fileName)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return size
    }

    /// Names of every file currently held by the vault (backup staging needs the
    /// full list, and trash purge needs to spot orphaned ciphertext).
    func storedFileNames() -> [String] {
        let urls = (try? fm.contentsOfDirectory(at: vaultDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls.map(\.lastPathComponent)
    }

    func totalSize() -> Int {
        let urls = (try? fm.contentsOfDirectory(at: vaultDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
    }
}
