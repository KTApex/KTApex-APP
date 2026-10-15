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
        return grouped.values.filter { $0.count > 1 }
    }

    static func formatted(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
