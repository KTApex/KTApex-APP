import Foundation
import SwiftData

@Model
final class VaultAlbum {
    var id: String = UUID().uuidString
    var name: String = ""
    var createdAt: Date = Date()
    var coverMediaID: String?
    @Relationship(deleteRule: .nullify, inverse: \VaultMedia.album) var media: [VaultMedia] = []
    init(name: String) { self.name = name }
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
    var album: VaultAlbum?
    init(fileName: String, encryptedFileName: String, mediaType: String, fileSize: Int = 0, contentHash: String = "") {
        self.fileName = fileName; self.encryptedFileName = encryptedFileName
        self.mediaType = mediaType; self.fileSize = fileSize; self.contentHash = contentHash
    }
    var isVideo: Bool { mediaType == "video" }
}
