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

    func totalSize() -> Int {
        let urls = (try? fm.contentsOfDirectory(at: vaultDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }.reduce(0, +)
    }
}
