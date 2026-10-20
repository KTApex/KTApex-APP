import Foundation

/// Storage statistics + duplicate detection (content-hash based, user confirms).
final class StorageService {
    static let shared = StorageService()
    private init() {}

    struct Stats {
        var totalBytes: Int = 0
        var photoBytes: Int = 0
        var videoBytes: Int = 0
        var fileCount: Int = 0
        var albumCount: Int = 0
    }

    func stats(media: [VaultMedia], albums: [VaultAlbum]) -> Stats {
        var s = Stats()
        s.albumCount = albums.count
        for m in media where !m.isInTrash {
            s.fileCount += 1
            s.totalBytes += m.fileSize
            if m.isVideo { s.videoBytes += m.fileSize } else { s.photoBytes += m.fileSize }
        }
        return s
    }

    /// Groups media sharing the same non-empty content hash. Never deletes anything.
    func duplicateGroups(in media: [VaultMedia]) -> [[VaultMedia]] {
        let grouped = Dictionary(grouping: media.filter { !$0.contentHash.isEmpty && !$0.isInTrash }, by: \.contentHash)
        return grouped.values
            .filter { $0.count > 1 }
            .map { group in
                group.sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id < rhs.id
                }
            }
            .sorted { lhs, rhs in
                (lhs.first?.contentHash ?? "") < (rhs.first?.contentHash ?? "")
            }
    }

    /// Moves redundant copies in `group` to Recently Deleted while keeping one copy
    /// (preserving favorite status and album labels on the kept item).
    @discardableResult
    func moveDuplicatesToTrash(
        in group: [VaultMedia],
        keeping retainedID: String? = nil,
        now: Date = Date()
    ) -> Int {
        let live = group.filter { !$0.isInTrash }
        guard live.count > 1 else { return 0 }
        let keeper = live.first { $0.id == retainedID } ?? live[0]
        var trashedCount = 0
        for item in live where item.id != keeper.id {
            if item.isFavorite { keeper.isFavorite = true }
            if keeper.caption.isEmpty, !item.caption.isEmpty { keeper.caption = item.caption }
            if keeper.tagsRaw.isEmpty, !item.tagsRaw.isEmpty { keeper.tagsRaw = item.tagsRaw }
            for albumID in item.albumIdentifiers where !keeper.albumIDs.contains(albumID) {
                keeper.albumIDs.append(albumID)
            }
            if keeper.album == nil, let primary = item.album {
                keeper.album = primary
            }
            item.isInTrash = true
            item.trashedAt = now
            item.albumIDs.removeAll()
            item.album = nil
            trashedCount += 1
        }
        return trashedCount
    }

    struct IntegrityReport: Equatable {
        var verifiedFiles: Int = 0
        var orphanedFilesRemoved: Int = 0
        var missingFileRows: Int = 0

        var summaryMessage: String {
            var lines: [String] = [
                "\(verifiedFiles) encrypted \(verifiedFiles == 1 ? "file" : "files") verified (AES-GCM + SHA-256)."
            ]
            if orphanedFilesRemoved > 0 {
                lines.append("Removed \(orphanedFilesRemoved) orphaned encrypted \(orphanedFilesRemoved == 1 ? "blob" : "blobs") from disk.")
            } else {
                lines.append("No orphaned encrypted files found.")
            }
            if missingFileRows > 0 {
                lines.append("\(missingFileRows) database \(missingFileRows == 1 ? "entry is" : "entries are") missing or failed verification.")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Verifies that every `VaultMedia` row's encrypted file on disk decrypts and matches
    /// its recorded SHA-256 content hash, and cleans up any unreferenced `.mvenc` files.
    @discardableResult
    func verifyAndRepairIntegrity(
        media: [VaultMedia],
        storage: VaultStorageService = .shared
    ) -> IntegrityReport {
        var report = IntegrityReport()
        let storedNames = Set(storage.storedFileNames())
        let referencedNames = Set(media.map(\.encryptedFileName).filter { !$0.isEmpty })

        for item in media {
            guard !item.encryptedFileName.isEmpty, storedNames.contains(item.encryptedFileName) else {
                report.missingFileRows += 1
                continue
            }
            if !item.contentHash.isEmpty {
                if storage.verify(fileName: item.encryptedFileName, matchesPlaintextHash: item.contentHash) {
                    report.verifiedFiles += 1
                } else {
                    report.missingFileRows += 1
                }
            } else if (try? storage.loadDecrypted(fileName: item.encryptedFileName)) != nil {
                report.verifiedFiles += 1
            } else {
                report.missingFileRows += 1
            }
        }

        for name in storedNames where name.hasSuffix(".mvenc") && !referencedNames.contains(name) {
            storage.delete(fileName: name)
            report.orphanedFilesRemoved += 1
        }

        return report
    }

    static func formatted(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
