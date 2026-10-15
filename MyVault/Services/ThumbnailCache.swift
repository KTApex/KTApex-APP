import Foundation
import UIKit

/// In-memory decrypted-thumbnail cache with NSCache. Full-resolution data is never cached.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 300 }

    func image(for mediaID: String) -> UIImage? {
        cache.object(forKey: mediaID as NSString)
    }

    func store(_ image: UIImage, for mediaID: String) {
        cache.setObject(image, forKey: mediaID as NSString)
    }

    func thumbnail(for item: VaultMedia, targetSize: CGFloat = 400) -> UIImage? {
        if let cached = image(for: item.id) { return cached }
        guard let data = try? VaultStorageService.shared.loadDecrypted(fileName: item.encryptedFileName) else { return nil }
        if item.isVideo {
            return nil
        }
        guard let img = UIImage(data: data) else { return nil }
        let scaled = img.preparingThumbnail(of: CGSize(width: targetSize, height: targetSize))
        if let scaled { store(scaled, for: item.id) }
        return scaled
    }

    func fullImage(for item: VaultMedia) -> UIImage? {
        guard !item.isVideo,
              let data = try? VaultStorageService.shared.loadDecrypted(fileName: item.encryptedFileName) else { return nil }
        return UIImage(data: data)
    }

    func clear() { cache.removeAllObjects() }
}
