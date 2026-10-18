import Foundation
import SwiftData

/// An album: a *label* over encrypted items, never a container of its own.
///
/// Membership lives on `VaultMedia.albumIDs` rather than on the `media`
/// relationship, because that relationship is to-one from the media side and an
/// item has to be able to sit in several albums at once. `media` is kept as a
/// derived view for restore and statistics code that needs "everything in this
/// album" without fetching the whole library.
@Model
final class VaultAlbum {
    var id: String = UUID().uuidString
    var name: String = ""
    var createdAt: Date = Date()
    /// Explicit cover chosen by the user. When nil — or when the chosen item has
    /// since been deleted — the album falls back to its newest live item, so a
    /// stored ID can never leave an album with a blank cover.
    var coverMediaID: String?
    @Relationship(deleteRule: .nullify, inverse: \VaultMedia.album) var media: [VaultMedia] = []
    init(name: String) { self.name = name }
    /// Items still in the vault. Trashed items are not counted, so an album never
    /// claims content the user has already deleted.
    var itemCount: Int { media.filter { $0.isInTrash == false }.count }
}

@Model
final class VaultMedia {
    var id: String = UUID().uuidString
    var fileName: String = ""
    var encryptedFileName: String = ""
    var mediaType: String = "photo"
    var createdAt: Date = Date()
    var isFavorite: Bool = false
    var isInTrash: Bool = false
    var trashedAt: Date?
    var fileSize: Int = 0
    var contentHash: String = ""
    var width: Int = 0
    var height: Int = 0
    var duration: Double = 0

    /// Album membership as stable album identifiers. This is the source of truth:
    /// it survives rename, album deletion and a backup round-trip without
    /// duplicating a single byte of encrypted media.
    ///
    /// A plain stored property with a default, which is what makes the automatic
    /// lightweight migration safe: an existing row simply has no value and decodes to
    /// the default rather than failing to open the store.
    var albumIDs: [String] = []

    /// Primary album relationship. Kept because `VaultAlbum.media` and the
    /// existing restore path are built on it; it mirrors `albumIDs.first`.
    var album: VaultAlbum?

    init(fileName: String, encryptedFileName: String, mediaType: String, fileSize: Int = 0, contentHash: String = "") {
        self.fileName = fileName; self.encryptedFileName = encryptedFileName
        self.mediaType = mediaType; self.fileSize = fileSize; self.contentHash = contentHash
    }

    var isVideo: Bool { mediaType == "video" }

    /// Every album this item belongs to, as a set of stable IDs.
    ///
    /// Folds in `album.id` so a row written before `albumIDs` existed — an older
    /// install, or a restore that went through the to-one field — still appears in
    /// its album instead of silently becoming unfiled.
    var albumIdentifiers: Set<String> {
        var ids = Set(albumIDs)
        if let primary = album?.id { ids.insert(primary) }
        return ids
    }

    func belongs(to album: VaultAlbum) -> Bool {
        belongs(toAlbumID: album.id)
    }

    func belongs(toAlbumID albumID: String) -> Bool {
        albumIDs.contains(albumID) || album?.id == albumID
    }

    /// Names of the albums this item carries, from whichever relationships the
    /// caller has loaded.
    ///
    /// Search matches album names, so a photo filed under "Summer Holiday" is found
    /// by typing "summer" without the library being decrypted or its files touched.
    /// Only the loaded relationships are consulted; nothing is fetched here, because
    /// this runs for every item on every keystroke.
    var albumNames: [String] {
        var names: [String] = []
        if let primary = album?.name, !primary.isEmpty { names.append(primary) }
        return names
    }
}
