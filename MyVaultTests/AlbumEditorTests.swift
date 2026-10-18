import XCTest
import SwiftData
@testable import MyVault

/// Album behaviour: membership, covers, ordering, and the promise that deleting an
/// album never deletes its photos.
///
/// Uses a real in-memory SwiftData container (the same approach as
/// `PortableBackupServiceTests`) so the rules are exercised against the actual model
/// shape rather than a stub.
///
/// `@MainActor`: SwiftData models are main-actor-isolated in this project, and the
/// album rules touch them directly.
@MainActor
final class AlbumEditorTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let schema = Schema([VaultAlbum.self, VaultMedia.self, SpecialDay.self,
                             ReminderConfiguration.self, AppSettings.self, BackupMetadata.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func media(_ name: String, in context: ModelContext, daysAgo: Int = 0) -> VaultMedia {
        let item = VaultMedia(fileName: name, encryptedFileName: "enc-\(name)",
                              mediaType: "photo", fileSize: 10, contentHash: name)
        item.createdAt = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        context.insert(item)
        return item
    }

    private func album(_ name: String, in context: ModelContext) -> VaultAlbum {
        let album = VaultAlbum(name: name)
        context.insert(album)
        return album
    }

    // MARK: - Create / rename

    func testCreateAndPersistAlbum() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        try context.save()

        XCTAssertEqual(holiday.name, "Holiday")
        XCTAssertEqual(try context.fetch(FetchDescriptor<VaultAlbum>()).count, 1)
    }

    func testRenameKeepsMembershipAndIdentity() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let item = media("beach", in: context)
        AlbumEditor.add([item], to: holiday)

        holiday.name = try XCTUnwrap(AlbumEditor.validatedName("  Summer 2026  "))
        try context.save()

        XCTAssertEqual(holiday.name, "Summer 2026")
        XCTAssertEqual(AlbumEditor.items(in: holiday, from: [item]).count, 1,
                       "a rename must not change what the album contains")
    }

    func testBlankNamesAreRejected() {
        XCTAssertNil(AlbumEditor.validatedName(""))
        XCTAssertNil(AlbumEditor.validatedName("   \n "))
        XCTAssertEqual(AlbumEditor.validatedName("  Trip "), "Trip")
    }

    // MARK: - Membership

    func testAddAndRemoveMembership() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let beach = media("beach", in: context)
        let surf = media("surf", in: context)

        XCTAssertTrue(AlbumEditor.add([beach, surf], to: holiday))
        XCTAssertTrue(beach.belongs(to: holiday))
        XCTAssertEqual(AlbumEditor.items(in: holiday, from: [beach, surf]).count, 2)

        XCTAssertTrue(AlbumEditor.remove([beach], from: holiday))
        XCTAssertFalse(beach.belongs(to: holiday))
        XCTAssertTrue(surf.belongs(to: holiday))
    }

    func testAddingTwiceIsANoOp() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let beach = media("beach", in: context)

        XCTAssertTrue(AlbumEditor.add([beach], to: holiday))
        XCTAssertFalse(AlbumEditor.add([beach], to: holiday), "re-adding must report no change")
        XCTAssertEqual(beach.albumIDs.filter { $0 == holiday.id }.count, 1,
                       "membership must not be duplicated")
    }

    func testItemCanBelongToSeveralAlbums() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let family = album("Family", in: context)
        let beach = media("beach", in: context)

        AlbumEditor.add([beach], to: holiday)
        AlbumEditor.add([beach], to: family)

        XCTAssertTrue(beach.belongs(to: holiday))
        XCTAssertTrue(beach.belongs(to: family))
        XCTAssertEqual(AlbumEditor.items(in: holiday, from: [beach]).count, 1)
        XCTAssertEqual(AlbumEditor.items(in: family, from: [beach]).count, 1)

        // Removing from one album must not remove it from the other.
        AlbumEditor.remove([beach], from: holiday)
        XCTAssertFalse(beach.belongs(to: holiday))
        XCTAssertTrue(beach.belongs(to: family))
    }

    func testMembershipSurvivesReload() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let beach = media("beach", in: context)
        AlbumEditor.add([beach], to: holiday)
        try context.save()

        // A second context on the same container is the closest unit-test analogue of
        // relaunching the app: it must read persisted membership, not the in-memory
        // objects.
        let reloaded = ModelContext(try XCTUnwrap(context.container))
        let albums = try reloaded.fetch(FetchDescriptor<VaultAlbum>())
        let items = try reloaded.fetch(FetchDescriptor<VaultMedia>())
        let reloadedAlbum = try XCTUnwrap(albums.first { $0.name == "Holiday" })

        XCTAssertEqual(AlbumEditor.items(in: reloadedAlbum, from: items).map(\.fileName), ["beach"])
        XCTAssertTrue(items[0].albumIDs.contains(reloadedAlbum.id))
    }

    func testDeletingAlbumKeepsPhotos() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let beach = media("beach", in: context)
        let surf = media("surf", in: context)
        AlbumEditor.add([beach, surf], to: holiday)
        try context.save()

        let detached = AlbumEditor.detachAll(in: [beach, surf], albumID: holiday.id)
        context.delete(holiday)
        try context.save()

        XCTAssertEqual(detached, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<VaultAlbum>()).count, 0)
        let remaining = try context.fetch(FetchDescriptor<VaultMedia>())
        XCTAssertEqual(remaining.count, 2, "deleting an album must never delete its photos")
        XCTAssertTrue(remaining.allSatisfy { $0.albumIDs.isEmpty },
                      "no item may keep a label pointing at a deleted album")
        XCTAssertTrue(remaining.allSatisfy { !$0.isInTrash })
    }

    func testEmptyAlbumIsHandled() throws {
        let context = try makeContext()
        let empty = album("Empty", in: context)
        let loose = media("loose", in: context)

        XCTAssertTrue(AlbumEditor.items(in: empty, from: [loose]).isEmpty)
        XCTAssertNil(AlbumEditor.cover(for: empty, from: [loose]))
        XCTAssertEqual(empty.itemCount(in: [loose]), 0)
    }

    func testTrashedItemLeavesTheAlbumButStaysInTheVault() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let beach = media("beach", in: context)
        AlbumEditor.add([beach], to: holiday)

        beach.isInTrash = true
        beach.trashedAt = Date()
        beach.albumIDs.removeAll()
        beach.album = nil

        XCTAssertTrue(AlbumEditor.items(in: holiday, from: [beach]).isEmpty,
                      "a trashed item must not be listed in an album")
        XCTAssertEqual(try context.fetch(FetchDescriptor<VaultMedia>()).count, 1,
                       "trashing is not deletion")
    }

    // MARK: - Covers

    func testExplicitCoverWinsAndFallsBackWhenMissing() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let newest = media("newest", in: context, daysAgo: 0)
        let oldest = media("oldest", in: context, daysAgo: 40)
        AlbumEditor.add([newest, oldest], to: holiday)

        // Default: the newest live member.
        XCTAssertEqual(AlbumEditor.cover(for: holiday, from: [newest, oldest])?.fileName, "newest")

        XCTAssertTrue(AlbumEditor.setCover(oldest, for: holiday))
        XCTAssertEqual(AlbumEditor.cover(for: holiday, from: [newest, oldest])?.fileName, "oldest")

        // The chosen item is trashed: the cover falls back instead of going blank.
        oldest.isInTrash = true
        XCTAssertEqual(AlbumEditor.cover(for: holiday, from: [newest, oldest])?.fileName, "newest")
    }

    func testCoverMustBeAMember() throws {
        let context = try makeContext()
        let holiday = album("Holiday", in: context)
        let outsider = media("outsider", in: context)

        XCTAssertFalse(AlbumEditor.setCover(outsider, for: holiday))
        XCTAssertNil(holiday.coverMediaID)
    }

    // MARK: - Ordering

    /// Case-insensitive, and — this matters — *deterministic*.
    ///
    /// Plain `localizedStandardCompare` leaves "Apple" vs "apple" to the locale, which
    /// on some locales orders them exactly reversed once case is folded. Two albums
    /// whose names differ only by case would then swap places between runs, so the
    /// tie is broken on the folded name and finally on the stable ID.
    func testAlbumsSortCaseInsensitivelyAndStably() {
        let collections = [
            [VaultAlbum(name: "zebra"), VaultAlbum(name: "Apple"),
             VaultAlbum(name: "apple"), VaultAlbum(name: "Mango")],
            [VaultAlbum(name: "apple"), VaultAlbum(name: "Apple"), VaultAlbum(name: "zebra")]
        ]
        for albums in collections {
            let sorted = AlbumEditor.sorted(albums).map { $0.name.lowercased() }
            XCTAssertEqual(sorted.first, "apple")
            XCTAssertEqual(sorted.last, "zebra")
            // Case-only duplicates must be adjacent, not spread through the list.
            let all = sorted.filter { $0 == "apple" }.count
            let leading = sorted.prefix(2).filter { $0 == "apple" }.count
            XCTAssertEqual(all, leading)
        }
    }

    func testAlbumsSortIsIndependentOfInputOrder() {
        let names = ["b", "A", "c", "a"]
        let forward = AlbumEditor.sorted(names.map { VaultAlbum(name: $0) }).map { $0.name.lowercased() }
        let backward = AlbumEditor.sorted(names.reversed().map { VaultAlbum(name: $0) }).map { $0.name.lowercased() }
        XCTAssertEqual(forward, backward, "sorting must not depend on insertion order")
    }
}
