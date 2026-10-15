import Foundation

/// Optional encrypted iCloud backup architecture (local-first by default).
///
/// Local-only mode (default): vault files stay in Application Support and are
/// included in the normal encrypted device backup. Nothing is uploaded by the app.
///
/// Encrypted backup mode (opt-in): each already-encrypted .mvenc blob is copied
/// to the app's iCloud Drive container as-is. Blobs are AES-GCM ciphertext, so
/// iCloud only ever sees opaque data. The vault key stays in the local Keychain
/// (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, non-synced), so a backup
/// is restorable on the same device but not readable from iCloud alone.
///
/// Limitation: restoring to a NEW device requires the user to transfer the key
/// (e.g. via encrypted export). This is documented in Settings rather than
/// weakened with a recoverable key.
final class BackupService {
    static let shared = BackupService()
    private init() {}

    var isiCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    func exportEncryptedBlobs() throws -> [URL] {
        let dir = VaultStorageService.shared.vaultDirectory
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    }
}
