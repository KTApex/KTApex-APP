import XCTest
@testable import MyVault

/// What the gallery shows is decided entirely by `GalleryComposer`, so the rules
/// (including what a search legitimately claims to match) are tested directly
/// rather than through the UI.
final class GalleryComposerTests: XCTestCase {

    private let calendar = Calendar.current

    private func media(
        name: String,
        type: String = "photo",
        size: Int = 100,
        daysAgo: Int = 0,
        favorite: Bool = false,
        trashed: Bool = false,
        album: VaultAlbum? = nil,
        now: Date = Date()
    ) -> VaultMedia {
        let item = VaultMedia(fileName: name, encryptedFileName: "enc-\(name)", mediaType: type, fileSize: size, contentHash: name)
        item.createdAt = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        item.isFavorite = favorite
        item.isInTrash = trashed
        item.album = album
        return item
    }

    private func date(daysAgo: Int, from reference: Date = Date()) -> Date {
        calendar.date(byAdding: .day, value: -daysAgo, to: reference) ?? reference
    }

    // MARK: - Filtering

    func testTrashedItemsAreNeverListed() {
        let items = [media(name: "visible"), media(name: "gone", trashed: true)]
        XCTAssertEqual(GalleryComposer.filter(items).map(\.fileName), ["visible"])
    }

    func testTypeAndFavoriteFilters() {
        let items = [
            media(name: "photo", type: "photo"),
            media(name: "clip", type: "video"),
            media(name: "loved", type: "photo", favorite: true)
        ]
        XCTAssertEqual(GalleryComposer.filter(items, filter: .photos).count, 2)
        XCTAssertEqual(GalleryComposer.filter(items, filter: .videos).map(\.fileName), ["clip"])
        XCTAssertEqual(GalleryComposer.filter(items, filter: .favorites).map(\.fileName), ["loved"])
    }

    func testAlbumFilterKeepsOnlyThatAlbumsLabeledItems() {
        let holiday = VaultAlbum(name: "Holiday")
        let work = VaultAlbum(name: "Work")
        let items = [
            media(name: "beach", album: holiday),
            media(name: "standup", album: work),
            media(name: "loose")
        ]
        XCTAssertEqual(GalleryComposer.filter(items, album: holiday).map(\.fileName), ["beach"])
        // The "albums" filter means "belongs to some album", independent of which.
        XCTAssertEqual(GalleryComposer.filter(items, filter: .albums).count, 2)
    }

    func testFiltersCombine() {
        let holiday = VaultAlbum(name: "Holiday")
        let items = [
            media(name: "beach", type: "photo", favorite: true, album: holiday),
            media(name: "surf", type: "video", favorite: true, album: holiday),
            media(name: "other", type: "photo", favorite: true)
        ]
        let result = GalleryComposer.filter(items, filter: .photos, album: holiday)
        XCTAssertEqual(result.map(\.fileName), ["beach"])
    }

    // MARK: - Searching

    func testSearchMatchesFileNameIgnoringCaseAndDiacritics() {
        let items = [media(name: "Café Menu.jpg"), media(name: "beach.jpg")]
        XCTAssertEqual(GalleryComposer.filter(items, search: "cafe").map(\.fileName), ["Café Menu.jpg"])
    }

    func testSearchMatchesAlbumName() {
        let holiday = VaultAlbum(name: "Summer Holiday")
        let items = [media(name: "one", album: holiday), media(name: "two")]
        XCTAssertEqual(GalleryComposer.filter(items, search: "summer").map(\.fileName), ["one"])
    }

    func testSearchMatchesMediaTypeWords() {
        let items = [media(name: "a", type: "photo"), media(name: "b", type: "video")]
        XCTAssertEqual(GalleryComposer.filter(items, search: "videos").map(\.fileName), ["b"])
        XCTAssertEqual(GalleryComposer.filter(items, search: "photo").map(\.fileName), ["a"])
    }

    func testSearchMatchesFavoriteWord() {
        let items = [media(name: "a", favorite: true), media(name: "b")]
        XCTAssertEqual(GalleryComposer.filter(items, search: "favourites").map(\.fileName), ["a"])
    }

    func testSearchMatchesYear() {
        // Both dates are fixed so the assertion cannot drift with the wall clock.
        let old = calendar.date(from: DateComponents(year: 2024, month: 5, day: 4))!
        let recent = calendar.date(from: DateComponents(year: 2026, month: 5, day: 4))!
        let items = [media(name: "old", now: old), media(name: "recent", now: recent)]

        XCTAssertEqual(GalleryComposer.filter(items, search: "2024").map(\.fileName), ["old"])
        XCTAssertEqual(GalleryComposer.filter(items, search: "2026").map(\.fileName), ["recent"])
    }

    func testBlankSearchKeepsEverything() {
        let items = [media(name: "a"), media(name: "b")]
        XCTAssertEqual(GalleryComposer.filter(items, search: "   ").count, 2)
    }

    // MARK: - Sorting

    func testSortOrders() {
        let items = [
            media(name: "old", size: 10, daysAgo: 10),
            media(name: "new", size: 30, daysAgo: 1),
            media(name: "middle", size: 20, daysAgo: 5)
        ]
        XCTAssertEqual(GalleryComposer.sort(items, by: .newest).map(\.fileName), ["new", "middle", "old"])
        XCTAssertEqual(GalleryComposer.sort(items, by: .oldest).map(\.fileName), ["old", "middle", "new"])
        XCTAssertEqual(GalleryComposer.sort(items, by: .largest).map(\.fileName), ["new", "middle", "old"])
        XCTAssertEqual(GalleryComposer.sort(items, by: .smallest).map(\.fileName), ["old", "middle", "new"])
    }

    // MARK: - Grouping

    func testDayGroupingLabelsTodayAndYesterday() {
        let now = Date()
        let items = [
            media(name: "today", daysAgo: 0, now: now),
            media(name: "yesterday", daysAgo: 1, now: now),
            media(name: "older", daysAgo: 40, now: now)
        ]
        let sections = GalleryComposer.sections(items, grouping: .day, calendar: calendar, now: now)
        XCTAssertEqual(sections.first?.title, "Today")
        XCTAssertEqual(sections.dropFirst().first?.title, "Yesterday")
        XCTAssertEqual(sections.first?.items.map(\.fileName), ["today"])
    }

    func testDayGroupingKeepsNewestFirstWhenInputIsSorted() {
        let now = Date()
        let items = [
            media(name: "today", daysAgo: 0, now: now),
            media(name: "yesterday", daysAgo: 1, now: now)
        ]
        let sorted = GalleryComposer.sort(items, by: .newest)
        let sections = GalleryComposer.sections(sorted, grouping: .day, calendar: calendar, now: now)
        XCTAssertEqual(sections.map(\.title), ["Today", "Yesterday"])
    }

    func testMonthAndYearGroupingCollapseItems() {
        // A fixed reference keeps "same month" meaningful whatever the real date is:
        // two items one day apart would straddle a month boundary on the 1st.
        let reference = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
        let items = [
            media(name: "a", daysAgo: 0, now: reference),
            media(name: "b", daysAgo: 1, now: reference),
            media(name: "c", daysAgo: 400, now: reference)
        ]
        let months = GalleryComposer.sections(GalleryComposer.sort(items, by: .newest), grouping: .month, calendar: calendar, now: reference)
        XCTAssertEqual(months.count, 2)
        XCTAssertEqual(months.first?.items.count, 2)
        XCTAssertEqual(months.first?.title, "This Month")

        let years = GalleryComposer.sections(GalleryComposer.sort(items, by: .newest), grouping: .year, calendar: calendar, now: reference)
        XCTAssertEqual(years.count, 2)
        XCTAssertEqual(years.first?.title, "This Year")
    }

    func testNoGroupingReturnsOneSection() {
        let items = [media(name: "a"), media(name: "b")]
        let sections = GalleryComposer.sections(items, grouping: .none)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.items.count, 2)
    }

    func testEmptyInputProducesNoSections() {
        XCTAssertTrue(GalleryComposer.sections([], grouping: .day).isEmpty)
        XCTAssertTrue(GalleryComposer.sections([], grouping: .none).isEmpty)
    }

    func testSectionSubtitleCountsItems() {
        let items = [media(name: "a"), media(name: "b")]
        let sections = GalleryComposer.sections(items, grouping: .none)
        XCTAssertEqual(sections.first?.subtitle, "2 items")
        XCTAssertEqual(GalleryComposer.sections([items[0]], grouping: .none).first?.subtitle, "1 item")
    }
}
