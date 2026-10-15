import Foundation
import Photos
import UIKit

/// Photo library access: authorization + optional original deletion after import.
final class PhotoLibraryService {
    static let shared = PhotoLibraryService()
    private init() {}

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    /// Deletes the original assets from the Photos library. Requires user confirmation in UI first.
    func deleteAssets(localIdentifiers: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    /// Exports a decrypted media file (image or video) back to the user's Photos
    /// library. Uses the Add-only authorization, which is the correct permission
    /// for saving new assets and does not grant read access to the library.
    func export(data: Data, isVideo: Bool) async throws {
        var status = authorizationStatus()
        if status == .notDetermined {
            status = await requestAddOnlyAuthorization()
        }
        guard status == .authorized || status == .limited else { throw VaultError.ioError }
        if isVideo {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            defer { try? FileManager.default.removeItem(at: url) }
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
        } else {
            guard let image = UIImage(data: data) else { throw VaultError.ioError }
            try await PHPhotoLibrary.shared().performChanges {
                _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
            }
        }
    }

    /// Thumbnail-safe image loading from a vault media item is handled by ThumbnailCache.
    static func thumbnailSize(for width: CGFloat) -> CGSize {
        CGSize(width: width * 2, height: width * 2)
    }
}
