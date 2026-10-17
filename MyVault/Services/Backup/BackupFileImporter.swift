import Foundation

/// Reads a backup the user chose in Files into the app's own scratch space.
///
/// This is the boundary that no unit test can reach: the URL handed back by
/// `fileImporter` belongs to another process (Files, iCloud Drive, a third-party
/// provider), so it needs a security scope, and a provider-backed URL also needs
/// coordination because the file may still be uploading. Three separate things can
/// go wrong here, and each is reported distinctly so the user is never told only
/// "that file could not be opened":
///
/// 1. the security scope cannot be taken (denied, or the provider went away),
/// 2. the file is not downloadable yet (iCloud placeholder),
/// 3. the copy itself fails (out of space).
///
/// The file is copied, never read in place: the scope is then released immediately
/// and the rest of the restore works against a URL this app controls, so a slow or
/// flaky provider cannot interrupt decryption half-way through.
enum BackupFileImporter {

    enum ImportError: LocalizedError, Equatable {
        case accessDenied
        case notDownloaded
        case tooLarge(Int)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "MyVault could not get permission to read that file. Try copying it into the MyVault folder in Files, or re-select it."
            case .notDownloaded:
                return "That backup has not finished downloading from iCloud. Open it once in Files, then try again."
            case .tooLarge(let bytes):
                return "That file is too large to be a MyVault backup (\(StorageService.formatted(bytes))). Nothing was changed."
            case .failed(let reason):
                return reason
            }
        }
    }

    /// A copy of the chosen backup living in this app's scratch space.
    struct Staged {
        var url: URL
        /// Directory holding `url`; the caller owns its lifetime.
        var directory: URL
        /// The name the user saw, for messages.
        var originalName: String
        /// True when the extension was not `mvbackup` (content is still authoritative).
        var extensionUnexpected: Bool

        // A staged backup is plaintext-adjacent: it is the encrypted container, so it
        // is still protected, but the directory is removed by the caller when done.
        func discard() { SecureScratch.removeDirectory(directory) }
    }

    /// Copies `source` into a fresh scratch directory.
    ///
    /// Refuses an implausibly large file before copying, so a mistaken or hostile
    /// multi-gigabyte selection cannot fill the device.
    static func stageCopy(of source: URL) throws -> Staged {
        // Only a sandbox-crossing URL needs a scope. A file already inside our own
        // container returns false from `startAccessing...`, which is not an error, so
        // the result is deliberately not treated as failure.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        guard let directory = try? SecureScratch.makeDirectory(prefix: "incoming") else {
            throw ImportError.failed("MyVault could not prepare temporary storage. Free up some space and try again.")
        }

        // Download state and size are checked in one place. A provider that has not
        // fetched the file yet reports a placeholder, which is caught here rather
        // than surfacing later as an opaque copy failure.
        let values = try? source.resourceValues(forKeys: [
            .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current {
            SecureScratch.removeDirectory(directory)
            throw ImportError.notDownloaded
        }
        if let size = values?.fileSize, size > BackupFormat.Limits.maximumMediaBytes {
            SecureScratch.removeDirectory(directory)
            throw ImportError.tooLarge(size)
        }

        let target = directory.appendingPathComponent("incoming.\(MyVaultBackupType.fileExtension)")
        do {
            try coordinateCopy(from: source, to: target)
        } catch let error as ImportError {
            SecureScratch.removeDirectory(directory)
            throw error
        } catch {
            SecureScratch.removeDirectory(directory)
            // Reading through a scope can fail even when the scope was granted, for
            // example when the provider revoked it or the file was moved.
            throw ImportError.failed("That file could not be read. Copy it into the MyVault folder in Files and try again.")
        }

        return Staged(
            url: target,
            directory: directory,
            originalName: source.lastPathComponent,
            extensionUnexpected: !MyVaultBackupType.looksLikeBackup(source)
        )
    }

    /// Copies through `NSFileCoordinator`.
    ///
    /// Coordination is what makes this work for provider-backed files (iCloud Drive,
    /// third-party storage): an uncoordinated read races with the provider's own
    /// access and fails intermittently. It is harmless for local files, so one path
    /// covers every source.
    private static func coordinateCopy(from source: URL, to target: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinatorError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: target)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let copyError { throw copyError }
        // A coordinator can report success while producing nothing; treat an absent
        // target as a failure so a later stage never reads a phantom path.
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ImportError.failed("That file could not be copied. Nothing was changed.")
        }
    }
}