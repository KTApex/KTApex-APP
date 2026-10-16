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
        var albumID: String?
        /// Name of the archive entry holding this item's bytes.
        var entryName: String
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
