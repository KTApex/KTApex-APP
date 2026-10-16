import Foundation

/// Policy values the share flow depends on, kept outside `ShareService` so they
/// can be used in default arguments (a default argument is evaluated outside the
/// type's actor isolation).
enum SharePolicy {
    /// How long a decrypted export outlives the share sheet.
    ///
    /// `UIActivityViewController` reports completion when the user *chooses* a
    /// target, which for AirDrop (and for "Save to Files") is before the transfer
    /// has actually read the bytes. Deleting immediately would hand the receiver a
    /// truncated file, so cleanup is deferred and leftover scratch directories are
    /// purged on the next launch as a backstop.
    static let exportLifetime: TimeInterval = 120
}

/// Turns vault media into files the system share sheet can hand to another app.
///
/// Uploading an `.mvenc` blob would be useless to the recipient and would leak the
/// vault's storage format, so sharing means decrypting — briefly — into scratch
/// space, handing over real media, then removing it. The rules this type enforces:
///
/// * everything is written to `SecureScratch` (complete file protection, excluded
///   from backup, one directory per share),
/// * the extension comes from the decrypted bytes, so WhatsApp/AirDrop/Files get a
///   file they can actually open,
/// * items are decrypted one at a time, so a 30-item share never holds 30
///   full-resolution payloads in memory at once,
/// * the decrypt runs off the main actor — otherwise sharing a few videos would
///   freeze the UI for seconds,
/// * nothing is deleted until the share sheet has finished with it (see
///   `scheduleCleanup`).
@MainActor
final class ShareService {
    static let shared = ShareService()
    private init() {}

    /// Everything the decrypt needs, captured on the main actor. `VaultMedia` is a
    /// SwiftData model and must never be read from another thread, so the fields are
    /// copied into this value first.
    struct ExportRequest: Sendable {
        let vaultFileName: String
        let displayName: String
        let mediaType: String
        let createdAt: Date
    }

    struct Prepared: Identifiable {
        let id = UUID()
        /// Plaintext export files, in the order the user selected them.
        let urls: [URL]
        /// Scratch directory holding `urls`.
        let directory: URL
        /// Display names of items that could not be decrypted. Reported to the
        /// user rather than silently dropped.
        let skipped: [String]

        var itemCount: Int { urls.count }
    }

    enum ShareError: LocalizedError, Equatable {
        case nothingSelected
        case nothingShareable

        var errorDescription: String? {
            switch self {
            case .nothingSelected: return "Select at least one photo or video to share."
            case .nothingShareable: return "None of the selected items could be prepared for sharing."
            }
        }
    }

    /// Decrypts each selected item into its own file, off the main actor.
    func prepare(_ items: [VaultMedia]) async throws -> Prepared {
        guard !items.isEmpty else { throw ShareError.nothingSelected }
        let requests = items.map {
            ExportRequest(
                vaultFileName: $0.encryptedFileName,
                displayName: $0.fileName,
                mediaType: $0.mediaType,
                createdAt: $0.createdAt
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try Self.prepareExports(requests)
        }.value
    }

    /// Removes a share's plaintext immediately (used when the user dismisses the
    /// sheet without choosing a target, where nothing can still be reading).
    func cleanup(_ prepared: Prepared) {
        SecureScratch.removeDirectory(prepared.directory)
    }

    /// Removes a share's plaintext after a delay, so in-flight transfers (AirDrop,
    /// Save to Files, messaging uploads) keep working.
    func scheduleCleanup(_ prepared: Prepared, after delay: TimeInterval = SharePolicy.exportLifetime) {
        let directory = prepared.directory
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            SecureScratch.removeDirectory(directory)
        }
    }

    /// Clears scratch space left over from a previous run — for example when the
    /// app was terminated while a share was in flight.
    static func purgeStaleExports() {
        SecureScratch.purgeStale()
    }

    // MARK: - Work that must stay off the main actor

    /// Partial failures are reported, not swallowed: sharing nine of ten items beats
    /// failing the whole batch, as long as the user is told about the tenth.
    nonisolated private static func prepareExports(_ requests: [ExportRequest]) throws -> Prepared {
        guard let directory = try? SecureScratch.makeDirectory(prefix: "share") else {
            throw ShareError.nothingShareable
        }
        var urls: [URL] = []
        var skipped: [String] = []
        var usedNames = Set<String>()

        for request in requests {
            do {
                // One item at a time: the plaintext is released before the next
                // decrypt starts.
                let data = try VaultStorageService.shared.loadDecrypted(fileName: request.vaultFileName)
                guard !data.isEmpty else {
                    skipped.append(request.displayName)
                    continue
                }
                let extensionHint = MediaSniff.sniff(data)?.fileExtension
                    ?? MediaSniff.fileExtension(forMediaType: request.mediaType)
                let name = uniqueName(
                    MediaFileName.resolve(
                        suggested: request.displayName,
                        capturedAt: request.createdAt,
                        fileExtension: extensionHint
                    ),
                    used: &usedNames
                )
                urls.append(try SecureScratch.write(data, named: name, in: directory))
            } catch {
                skipped.append(request.displayName)
            }
        }

        guard !urls.isEmpty else {
            SecureScratch.removeDirectory(directory)
            throw ShareError.nothingShareable
        }
        return Prepared(urls: urls, directory: directory, skipped: skipped)
    }

    /// Two items can legitimately share a name (the same photo imported twice), and
    /// two files with one name would collide in `directory`.
    nonisolated private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        guard used.contains(name) else {
            used.insert(name)
            return name
        }
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 2
        var candidate = name
        while used.contains(candidate) {
            candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            index += 1
        }
        used.insert(candidate)
        return candidate
    }
}
