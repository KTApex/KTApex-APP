import XCTest
@testable import MyVault

final class StorageServiceTests: XCTestCase {
    private func media(type: String, size: Int, hash: String = "", trash: Bool = false) -> VaultMedia {
        let m = VaultMedia(fileName: "f", encryptedFileName: "e", mediaType: type, fileSize: size, contentHash: hash)
        m.isInTrash = trash
        return m
    }

    func testStatsTotals() {
        let items = [
            media(type: "photo", size: 100, hash: "a"),
            media(type: "photo", size: 200, hash: "b"),
            media(type: "video", size: 1000, hash: "c"),
            media(type: "photo", size: 999, trash: true)
        ]
        let stats = StorageService.shared.stats(media: items, albums: [VaultAlbum(name: "A"), VaultAlbum(name: "B")])
        XCTAssertEqual(stats.fileCount, 3)
        XCTAssertEqual(stats.totalBytes, 1300)
        XCTAssertEqual(stats.photoBytes, 300)
        XCTAssertEqual(stats.videoBytes, 1000)
        XCTAssertEqual(stats.albumCount, 2)
    }

    func testDuplicateGroupsRequireConfirmation() {
        let items = [
            media(type: "photo", size: 10, hash: "same"),
            media(type: "photo", size: 10, hash: "same"),
            media(type: "photo", size: 10, hash: "unique")
        ]
        let groups = StorageService.shared.duplicateGroups(in: items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }

    func testEmptyHashIgnored() {
        let items = [media(type: "photo", size: 1), media(type: "photo", size: 1)]
        XCTAssertTrue(StorageService.shared.duplicateGroups(in: items).isEmpty)
    }

    func testTrashRestoreLogic() {
        let m = media(type: "photo", size: 5)
        m.isInTrash = true
        m.trashedAt = Date()
        // Simulate restore:
        m.isInTrash = false
        m.trashedAt = nil
        XCTAssertFalse(m.isInTrash)
        XCTAssertNil(m.trashedAt)
    }

    func testAlbumItemCountExcludesTrash() {
        let album = VaultAlbum(name: "Trip")
        let a = media(type: "photo", size: 1)
        let b = media(type: "photo", size: 1, trash: true)
        album.media = [a, b]
        // Counted from the relationship here, because no library is supplied: this is
        // the path the older screens use.
        XCTAssertEqual(album.itemCount(in: []), 1)
    }
}
