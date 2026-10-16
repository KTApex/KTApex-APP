import Foundation

/// What the gallery is showing. Deliberately small: each case has to be
/// explainable in one word on a segmented control.
enum MediaFilter: String, CaseIterable, Identifiable {
    case all, photos, videos, favorites, albums

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .photos: return "Photos"
        case .videos: return "Videos"
        case .favorites: return "Favorites"
        case .albums: return "Albums"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .photos: return "photo"
        case .videos: return "video"
        case .favorites: return "heart"
        case .albums: return "rectangle.stack"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: return "Nothing in the vault yet."
        case .photos: return "No photos in the vault yet."
        case .videos: return "No videos in the vault yet."
        case .favorites: return "Nothing has been favorited yet."
        case .albums: return "No media has been added to an album yet."
        }
    }
}

enum GallerySort: String, CaseIterable, Identifiable {
    case newest, oldest, largest, smallest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .largest: return "Largest first"
        case .smallest: return "Smallest first"
        }
    }

    var symbol: String {
        switch self {
        case .newest, .largest: return "arrow.down"
        case .oldest, .smallest: return "arrow.up"
        }
    }
}

enum GalleryGrouping: String, CaseIterable, Identifiable {
    case day, month, year, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "By Day"
        case .month: return "By Month"
        case .year: return "By Year"
        case .none: return "No Grouping"
        }
    }
}

/// One rendered group of the gallery.
struct GallerySection: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let items: [VaultMedia]

    static func == (lhs: GallerySection, rhs: GallerySection) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.items.count == rhs.items.count
    }
}

/// Filtering, search and grouping for the gallery.
///
/// Kept free of SwiftUI so the rules that decide *what the user sees* (and what a
/// search actually claims to match) can be tested directly. Search only matches
/// metadata the app really holds — a file name, an album name, a media type, a
/// date, a favorite flag. It never implies image recognition.
enum GalleryComposer {

    // MARK: - Filter + search

    static func matches(_ item: VaultMedia, search: String, album: VaultAlbum? = nil) -> Bool {
        guard !search.isBlank else { return true }
        let needle = folded(search.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }

        // Folded on both sides so "cafe" finds "Café" and "CAFÉ" alike.
        // `localizedCaseInsensitiveContains` only folds case, not diacritics, so
        // "cafe" would miss "Café.jpg" if it were used here.
        if folded(item.fileName).contains(needle) { return true }
        if let albumName = item.album?.name, folded(albumName).contains(needle) { return true }
        if DateSearchTerms.terms(for: item.createdAt).contains(where: { folded($0).contains(needle) }) { return true }
        if SearchKeywords.mediaTypeTerms(for: item).contains(needle) { return true }
        if SearchKeywords.favoriteTerms.contains(needle), item.isFavorite { return true }
        return false
    }

    /// Case- and diacritic-insensitive form used for every search comparison.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    static func filter(
        _ items: [VaultMedia],
        search: String = "",
        filter: MediaFilter = .all,
        album: VaultAlbum? = nil
    ) -> [VaultMedia] {
        items.filter { item in
            guard !item.isInTrash else { return false }
            if let album, item.album?.id != album.id { return false }
            switch filter {
            case .all: break
            case .photos: if item.isVideo { return false }
            case .videos: if !item.isVideo { return false }
            case .favorites: if !item.isFavorite { return false }
            case .albums: if item.album == nil { return false }
            }
            return matches(item, search: search, album: album)
        }
    }

    static func sort(_ items: [VaultMedia], by order: GallerySort) -> [VaultMedia] {
        switch order {
        case .newest: return items.sorted { $0.createdAt > $1.createdAt }
        case .oldest: return items.sorted { $0.createdAt < $1.createdAt }
        case .largest: return items.sorted { $0.fileSize > $1.fileSize }
        case .smallest: return items.sorted { $0.fileSize < $1.fileSize }
        }
    }

    // MARK: - Grouping

    static func sections(
        _ items: [VaultMedia],
        grouping: GalleryGrouping,
        calendar: Calendar = .current,
        now: Date = Date(),
        locale: Locale = .current
    ) -> [GallerySection] {
        guard grouping != .none else {
            guard !items.isEmpty else { return [] }
            return [GallerySection(id: "all", title: "All Items", subtitle: count(items), items: items)]
        }

        var order: [String] = []
        var buckets: [String: [VaultMedia]] = [:]
        var titles: [String: String] = [:]

        for item in items {
            let key = self.key(for: item.createdAt, grouping: grouping, calendar: calendar)
            if buckets[key] == nil {
                buckets[key] = []
                titles[key] = self.title(for: item.createdAt, grouping: grouping, calendar: calendar, now: now, locale: locale)
                order.append(key)
            }
            buckets[key]?.append(item)
        }

        return order.compactMap { key in
            guard let items = buckets[key] else { return nil }
            return GallerySection(id: key, title: titles[key] ?? key, subtitle: count(items), items: items)
        }
    }

    private static func count(_ items: [VaultMedia]) -> String {
        "\(items.count) \(items.count == 1 ? "item" : "items")"
    }

    private static func key(for date: Date, grouping: GalleryGrouping, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        switch grouping {
        case .day: return String(format: "d-%04d-%02d-%02d", year, month, day)
        case .month: return String(format: "m-%04d-%02d", year, month)
        case .year: return String(format: "y-%04d", year)
        case .none: return "all"
        }
    }

    private static func title(
        for date: Date,
        grouping: GalleryGrouping,
        calendar: Calendar,
        now: Date,
        locale: Locale
    ) -> String {
        switch grouping {
        case .day:
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM yyyy")
            return formatter.string(from: date)
        case .month:
            if calendar.isDate(date, equalTo: now, toGranularity: .month) { return "This Month" }
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: date)
        case .year:
            let year = calendar.component(.year, from: date)
            let currentYear = calendar.component(.year, from: now)
            return year == currentYear ? "This Year" : "\(year)"
        case .none:
            return "All Items"
        }
    }
}

/// Search terms derived from a media item's real metadata.
enum SearchKeywords {
    /// Words a user might type when they mean the media type.
    static func mediaTypeTerms(for item: VaultMedia) -> [String] {
        item.isVideo ? ["video", "videos", "movie", "clip"] : ["photo", "photos", "image", "picture"]
    }

    static let favoriteTerms: Set<String> = ["favorite", "favorites", "favourite", "favourites", "loved", "starred"]
}

/// Date text a search can match, so typing "october" or "2026" finds the right
/// items without pretending to understand them.
enum DateSearchTerms {
    private static let formatters: [DateFormatter] = {
        let identifiers = ["y", "yyyy", "MMMM", "MMM", "MMMM yyyy", "d MMMM yyyy", "EEEE"]
        return identifiers.map { format in
            let formatter = DateFormatter()
            formatter.dateFormat = format
            return formatter
        }
    }()

    static func terms(for date: Date, locale: Locale = .current) -> [String] {
        formatters.map { formatter in
            formatter.locale = locale
            return formatter.string(from: date).lowercased()
        }
    }
}
