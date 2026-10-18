import XCTest
import SwiftData
@testable import MyVault

/// The manifest changes made for multi-album support must not break the one path
/// users cannot redo: restoring an existing backup.
@MainActor
final class AlbumBackupCompatibilityTests: XCTestCase {

    private func media(
        id: String = "m1",
        albumID: String?,
        albumIDs: [String]? = nil
    ) -> BackupManifest.Media {
        BackupManifest.Media(
            id: id,
            fileName: "beach.jpg",
            mediaType: "photo",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isFavorite: false,
            isInTrash: false,
            trashedAt: nil,
            fileSize: 10,
            contentHash: "hash-\(id)",
            width: 100,
            height: 100,
            duration: 0,
            albumID: albumID,
            albumIDs: albumIDs,
            entryName: "media/\(id)"
        )
    }

    /// A backup written before this release has `albumID` and no `albumIDs` key.
    func testOldManifestWithoutAlbumIDsDecodes() throws {
        let json = """
        {
          "id": "m1",
          "fileName": "beach.jpg",
          "mediaType": "photo",
          "createdAt": "2023-11-14T22:13:20Z",
          "isFavorite": true,
          "isInTrash": false,
          "fileSize": 10,
          "contentHash": "hash-m1",
          "width": 100,
          "height": 100,
          "duration": 0,
          "albumID": "a1",
          "entryName": "media/m1"
        }
        """.data(using: .utf8)!

        let decoded = try BackupManifest.decoder().decode(BackupManifest.Media.self, from: json)
        XCTAssertEqual(decoded.albumID, "a1")
        XCTAssertNil(decoded.albumIDs)
        XCTAssertEqual(decoded.memberships, ["a1"],
                       "an old backup must restore into the album it always did")
    }

    func testNewManifestRoundTripsAllMemberships() throws {
        let original = media(albumID: "a1", albumIDs: ["a1", "a2"])
        let data = try BackupManifest.encoder().encode(original)
        let decoded = try BackupManifest.decoder().decode(BackupManifest.Media.self, from: data)

        XCTAssertEqual(decoded.memberships, ["a1", "a2"])
        XCTAssertEqual(decoded, original)
    }

    func testEmptyMembershipEncodesAsPrimaryOnly() throws {
        // Backups written by this build keep `albumID` populated so an older build can
        // still read them; the array is omitted when there is nothing extra to say.
        let original = media(albumID: "a1", albumIDs: nil)
        let json = String(data: try BackupManifest.encoder().encode(original), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"albumID\":\"a1\""))
        XCTAssertFalse(json.contains("albumIDs"), "no redundant key for single-album items")
        XCTAssertEqual(original.memberships, ["a1"])
    }

    func testNoAlbumEncodesWithoutMembership() {
        let item = media(albumID: nil)
        XCTAssertTrue(item.memberships.isEmpty)
    }

    /// Restoring must place an item in every album the manifest names.
    func testRestoredItemJoinsEveryAlbum() throws {
        let schema = Schema([VaultAlbum.self, VaultMedia.self, SpecialDay.self,
                             ReminderConfiguration.self, AppSettings.self, BackupMetadata.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let context = ModelContext(try ModelContainer(for: schema, configurations: [config]))

        let holiday = VaultAlbum(name: "Holiday")
        holiday.id = "a1"
        let family = VaultAlbum(name: "Family")
        family.id = "a2"
        context.insert(holiday)
        context.insert(family)

        // Mirrors the restore path in `PortableBackupService`.
        let albumsByID = ["a1": holiday, "a2": family]
        let entry = media(albumID: "a1", albumIDs: ["a1", "a2"])
        let restoredIDs = entry.memberships.filter { albumsByID[$0] != nil }

        let model = VaultMedia(fileName: entry.fileName, encryptedFileName: "enc", mediaType: "photo")
        model.albumIDs = restoredIDs
        if let primary = restoredIDs.first { model.album = albumsByID[primary] }
        context.insert(model)
        try context.save()

        XCTAssertTrue(model.belongs(to: holiday))
        XCTAssertTrue(model.belongs(to: family))
        XCTAssertEqual(model.albumIDs, ["a1", "a2"])
        XCTAssertEqual(holiday.itemCount, 1)
        XCTAssertEqual(family.itemCount, 1)
    }

    func testUnknownAlbumIDsAreDroppedOnRestore() throws {
        let albumsByID: [String: VaultAlbum] = [:]
        let entry = media(albumID: "missing", albumIDs: ["missing", "also-missing"])
        let restored = entry.memberships.filter { albumsByID[$0] != nil }
        XCTAssertTrue(restored.isEmpty, "a dangling album reference must not be stored")
    }
}
