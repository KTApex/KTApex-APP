import Foundation
import SwiftData

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

    enum BackupServiceError: LocalizedError {
        case iCloudUnavailable

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable:
                return "iCloud Drive is not available on this device. Sign in to iCloud or use a password-protected portable backup instead."
            }
        }
    }

    var isiCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "mv.backupEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "mv.backupEnabled") }
    }

    func exportEncryptedBlobs() throws -> [URL] {
        let dir = VaultStorageService.shared.vaultDirectory
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "mvenc" }
    }

    func destinationDirectory(override: URL? = nil) throws -> URL {
        if let override { return override }
        guard isiCloudAvailable,
              let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            throw BackupServiceError.iCloudUnavailable
        }
        return container.appendingPathComponent("Documents/VaultCiphertext", isDirectory: true)
    }

    @MainActor
    @discardableResult
    func syncEncryptedBlobs(
        in context: ModelContext,
        destinationOverride: URL? = nil
    ) throws -> BackupMetadata {
        let metadata = fetchOrCreateMetadata(in: context)
        metadata.isEnabled = isEnabled
        let targetDir = try destinationDirectory(override: destinationOverride)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let blobs = try exportEncryptedBlobs()
        let activeNames = Set(blobs.map(\.lastPathComponent))

        for blob in blobs {
            let destination = targetDir.appendingPathComponent(blob.lastPathComponent)
            let data = try Data(contentsOf: blob)
            try data.write(to: destination, options: .atomic)
        }

        let existing = (try? FileManager.default.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil)) ?? []
        for url in existing where url.pathExtension == "mvenc" && !activeNames.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }

        metadata.lastBackupAt = Date()
        metadata.encryptedItemCount = blobs.count
        try context.save()
        return metadata
    }

    @MainActor
    func fetchOrCreateMetadata(in context: ModelContext) -> BackupMetadata {
        if let existing = (try? context.fetch(FetchDescriptor<BackupMetadata>()))?.first {
            return existing
        }
        let created = BackupMetadata()
        created.isEnabled = isEnabled
        context.insert(created)
        return created
    }
}
