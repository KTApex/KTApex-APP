import Foundation
import SwiftData

enum SpecialDayType: String, Codable, CaseIterable { case birthday, anniversary, wedding, graduation, relationship, custom
    var symbol: String {
        switch self { case .birthday: return "gift.fill"; case .anniversary: return "heart.fill"; case .wedding: return "rings"; case .graduation: return "graduationcap.fill"; case .relationship: return "heart.circle.fill"; case .custom: return "star.fill" }
    }
    var displayName: String { rawValue.capitalized }
}

@Model
final class SpecialDay {
    var id: String = UUID().uuidString
    var title: String = ""
    var date: Date = Date()
    var notes: String = ""
    var typeRaw: String = SpecialDayType.custom.rawValue
    var repeatsYearly: Bool = true
    var photoFileName: String?
    var linkedAlbumID: String?
    /// Persisted as CSV because SwiftData cannot persist `[Int]` directly.
    var reminderDaysRaw: String = "0,1,7"
    var reminderDays: [Int] {
        get { reminderDaysRaw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        set { reminderDaysRaw = newValue.sorted().map(String.init).joined(separator: ",") }
    }
    var reminderTimeHour: Int = 9
    var reminderTimeMinute: Int = 0
    var createdAt: Date = Date()
    init(title: String, date: Date, type: SpecialDayType = .custom) { self.title = title; self.date = date; self.typeRaw = type.rawValue }
    var type: SpecialDayType { SpecialDayType(rawValue: typeRaw) ?? .custom }

    /// Resolves the chosen cover item from the live vault library. Matches either the
    /// item's stable `id` or `encryptedFileName`, excluding trashed items.
    func coverMedia(in library: [VaultMedia]) -> VaultMedia? {
        guard let key = photoFileName, !key.isEmpty else { return nil }
        return library.first { !$0.isInTrash && ($0.id == key || $0.encryptedFileName == key) }
    }

    /// Resolves the linked album from the current album list.
    func linkedAlbum(in albums: [VaultAlbum]) -> VaultAlbum? {
        guard let albumID = linkedAlbumID, !albumID.isEmpty else { return nil }
        return albums.first { $0.id == albumID }
    }
}

@Model
final class ReminderConfiguration {
    var id: String = UUID().uuidString
    var specialDayID: String = ""
    var daysBefore: Int = 1
    var timeHour: Int = 9
    var timeMinute: Int = 0
    var isEnabled: Bool = true
    init(specialDayID: String, daysBefore: Int) { self.specialDayID = specialDayID; self.daysBefore = daysBefore }
}
