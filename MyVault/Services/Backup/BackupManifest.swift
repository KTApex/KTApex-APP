import Foundation

/// Everything a backup restores, in one Codable document that is itself an
/// encrypted entry in the container (so it is never readable without the password).
///
/// The manifest deliberately holds **no** credentials of any kind: no PIN verifier,
/// no vault key, no failed-attempt or lockout state. Restoring onto a new device
/// therefore brings back the user's media and organisation while leaving that
/// device's own unlock setup in place.
struct BackupManifest: Codable, Equatable {

    /// Bumped when the *shape* changes in a way an older reader cannot interpret.
    static let currentSchema = 1

    var schemaVersion: Int
    var createdAt: Date
    var appVersion: String
    var counts: Counts
    var albums: [Album]
    var media: [Media]
    var specialDays: [SpecialDay]
    var reminders: [Reminder]
    var settings: Settings

    struct Counts: Codable, Equatable {
        var media: Int
        var albums: Int
        var specialDays: Int
        var trashedMedia: Int
        var totalMediaBytes: Int
    }

    struct Album: Codable, Equatable {
        var id: String
        var name: String
        var createdAt: Date
        var coverMediaID: String?
    }

    struct Media: Codable, Equatable {
        var id: String
        var fileName: String
        var mediaType: String
        var createdAt: Date
        var isFavorite: Bool
        var isInTrash: Bool
        var trashedAt: Date?
        var fileSize: Int
        var contentHash: String
        var width: Int
        var height: Int
        var duration: Double
        /// Primary album, written since schema 1. Kept so a backup taken by this build
        /// is still readable by an older one and vice versa.
        var albumID: String?
        /// Every album this item belongs to.
        ///
        /// Optional so backups written before multi-album support decode unchanged
        /// (the key is simply absent), and the restore path falls back to `albumID` in
        /// that case. Additive, so the schema version does not need to change.
        var albumIDs: [String]?
        /// Name of the archive entry holding this item's bytes.
        var entryName: String

        /// Decodes leniently for the two fields added after schema 1.
        ///
        /// A synthesised decoder requires every key even when the property is
        /// optional, so a backup written by an older build — which has `albumID` but no
        /// `albumIDs` — would fail to load. Restoring a user's own backup is the one
        /// path that must never break, so absence is treated as "not present" rather
        /// than as corruption.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            fileName = try container.decode(String.self, forKey: .fileName)
            mediaType = try container.decode(String.self, forKey: .mediaType)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
            isInTrash = try container.decodeIfPresent(Bool.self, forKey: .isInTrash) ?? false
            trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
            fileSize = try container.decodeIfPresent(Int.self, forKey: .fileSize) ?? 0
            contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
            width = try container.decodeIfPresent(Int.self, forKey: .width) ?? 0
            height = try container.decodeIfPresent(Int.self, forKey: .height) ?? 0
            duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            albumID = try container.decodeIfPresent(String.self, forKey: .albumID)
            albumIDs = try container.decodeIfPresent([String].self, forKey: .albumIDs)
            entryName = try container.decode(String.self, forKey: .entryName)
        }

        /// Memberwise initialiser, preserved so call sites read as before.
        init(
            id: String,
            fileName: String,
            mediaType: String,
            createdAt: Date,
            isFavorite: Bool,
            isInTrash: Bool,
            trashedAt: Date?,
            fileSize: Int,
            contentHash: String,
            width: Int,
            height: Int,
            duration: Double,
            albumID: String?,
            albumIDs: [String]? = nil,
            entryName: String
        ) {
            self.id = id
            self.fileName = fileName
            self.mediaType = mediaType
            self.createdAt = createdAt
            self.isFavorite = isFavorite
            self.isInTrash = isInTrash
            self.trashedAt = trashedAt
            self.fileSize = fileSize
            self.contentHash = contentHash
            self.width = width
            self.height = height
            self.duration = duration
            self.albumID = albumID
            self.albumIDs = albumIDs
            self.entryName = entryName
        }

        /// Every album this entry claims, whichever shape the backup used.
        var memberships: [String] {
            if let albumIDs, !albumIDs.isEmpty { return albumIDs }
            if let albumID { return [albumID] }
            return []
        }
    }

    struct SpecialDay: Codable, Equatable {
        var id: String
        var title: String
        var date: Date
        var notes: String
        var typeRaw: String
        var repeatsYearly: Bool
        var reminderDays: [Int]
        var reminderTimeHour: Int
        var reminderTimeMinute: Int
        var createdAt: Date
    }

    struct Reminder: Codable, Equatable {
        var id: String
        var specialDayID: String
        var daysBefore: Int
        var timeHour: Int
        var timeMinute: Int
        var isEnabled: Bool
    }

    /// App preferences worth carrying across devices. Security *settings* are not
    /// restored: biometrics and the PIN stay whatever this device already has.
    struct Settings: Codable, Equatable {
        var autoLockSeconds: Int?
        var themeMode: String?
        var accent: String?
        var galleryColumns: Int?
    }

    // MARK: - Coders

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var photoCount: Int { media.filter { $0.mediaType != "video" }.count }
    var videoCount: Int { media.filter { $0.mediaType == "video" }.count }
    var liveCount: Int { media.filter { !$0.isInTrash }.count }

    /// Wording used by the restore preview. Derived only from the manifest, so it
    /// cannot promise anything the backup does not contain.
    var previewLines: [String] {
        var lines: [String] = []
        lines.append("\(liveCount) item\(liveCount == 1 ? "" : "s") — \(photoCount) photo\(photoCount == 1 ? "" : "s"), \(videoCount) video\(videoCount == 1 ? "" : "s")")
        if counts.trashedMedia > 0 { lines.append("\(counts.trashedMedia) item\(counts.trashedMedia == 1 ? "" : "s") in Recently Deleted") }
        if !albums.isEmpty { lines.append("\(albums.count) album\(albums.count == 1 ? "" : "s")") }
        if !specialDays.isEmpty { lines.append("\(specialDays.count) special day\(specialDays.count == 1 ? "" : "s")") }
        if !reminders.isEmpty { lines.append("\(reminders.count) reminder\(reminders.count == 1 ? "" : "s")") }
        lines.append(StorageService.formatted(counts.totalMediaBytes))
        return lines
    }
}
