import Foundation
import Photos
import UIKit

/// How much access MyVault currently has to the user's photo library.
///
/// `limited` is the state iOS 14+ gives a user who picked specific items. It is
/// deliberately *not* treated as a failure: media can be read, exported and — for
/// the items the user did select — removed. What it cannot do is see or remove
/// anything outside that selection, which is why the import flow reports which
/// originals could not be removed instead of pretending the whole batch worked.
enum PhotoAccess: Equatable {
    case notDetermined
    case denied
    case limited
    case authorized

    /// Can the app read assets (and therefore read metadata / delete them)?
    var canReadLibrary: Bool { self == .authorized || self == .limited }

    /// Can the app write new assets (save exports)?
    var canAddAssets: Bool { self != .denied && self != .notDetermined }

    /// Human-readable explanation used by the import and settings screens.
    var explanation: String {
        switch self {
        case .authorized:
            return "MyVault can see your whole Photos library, so originals can be removed after a verified import."
        case .limited:
            return "MyVault can only see the items you selected in Photos. Originals outside that selection cannot be removed."
        case .denied:
            return "MyVault has no access to Photos. Items you import are still encrypted into the vault, but the originals stay in Photos."
        case .notDetermined:
            return "MyVault has not asked for Photos access yet. Without it, the originals cannot be removed from Photos."
        }
    }
}

/// Outcome of one attempt to remove imported originals from Apple Photos.
///
/// Partial results are normal under limited access, so the caller reports exactly
/// what happened instead of a single success/failure flag. Nothing here ever
/// touches the vault copies: a failed removal keeps them.
struct OriginalDeleteOutcome: Equatable {
    /// Assets that Photos confirmed as deleted.
    var deleted: [String] = []
    /// Assets that could not be found — typically outside a limited selection,
    /// or already deleted by the user.
    var unavailable: [String] = []
    /// Assets Photos refused to delete (the change request threw).
    var failed: [String] = []
    var errorMessage: String?

    var allDeleted: Bool { failed.isEmpty && unavailable.isEmpty && !deleted.isEmpty }

    var keptCount: Int { failed.count + unavailable.count }
}

/// Photo library access: authorization, original metadata, and the *only* place
/// in the app that deletes anything from Apple Photos.
///
/// Every deletion path goes through `deleteOriginals(_:)`, which is only ever
/// called by the UI after the encrypted vault copy has been written, read back and
/// hash-verified. This type never deletes vault data.
final class PhotoLibraryService {
    static let shared = PhotoLibraryService()
    private init() {}

    // MARK: - Authorization

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func access() -> PhotoAccess {
        Self.map(authorizationStatus())
    }

    static func map(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Requests read/write access. Read/write (not add-only) is required because
    /// removing the imported original is a library *change*.
    func requestAuthorization() async -> PhotoAccess {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    /// Re-reads the status after the user changed it in Settings.
    func refreshAccess() -> PhotoAccess { access() }

    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    /// Opens the system picker that lets a user widen a limited selection without
    /// leaving the app. Falls back to Settings when there is nothing to present on
    /// top of.
    @discardableResult
    func presentLimitedLibraryPicker() -> Bool {
        guard authorizationStatus() == .limited else { return false }
        guard let controller = Self.topViewController() else { return false }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
        return true
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        Task { @MainActor in
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard var controller = active?.keyWindow?.rootViewController
                ?? active?.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return nil }
        while let presented = controller.presentedViewController { controller = presented }
        return controller
    }

    // MARK: - Original metadata

    /// What the Photos library knows about an asset. Used to give imported media a
    /// real name and its true capture date instead of a fabricated one.
    struct OriginalInfo {
        var filename: String?
        var capturedAt: Date?
        var kind: MediaKind?
    }

    /// Returns `nil` when the asset is not visible to the app — which happens for
    /// assets outside a limited selection, so callers must treat `nil` as "unknown",
    /// never as "does not exist".
    func info(forAssetIdentifier identifier: String) -> OriginalInfo? {
        guard access().canReadLibrary else { return nil }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = assets.firstObject else { return nil }
        var info = OriginalInfo()
        info.capturedAt = asset.creationDate
        info.kind = asset.mediaType == .video ? .video : .image
        // `PHAssetResource.originalFilename` is public API; the PHAsset `filename`
        // key is not, and must not be used.
        if let resource = assetResource(for: asset) {
            info.filename = resource.originalFilename
        }
        return info
    }

    /// The asset identifier as the library currently reports it, if the asset is
    /// still reachable.
    func isAssetAvailable(_ identifier: String) -> Bool {
        guard access().canReadLibrary else { return false }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).count > 0
    }

    private func assetResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto, .fullSizeVideo]
        for type in preferred {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    // MARK: - Deleting originals

    /// Removes the given assets from the user's Photos library.
    ///
    /// Called only after the vault copy has been verified. Never throws: every
    /// failure mode (no permission, asset not visible under limited access, the
    /// change request being rejected) comes back as a partial `OriginalDeleteOutcome`
    /// so the UI can tell the user exactly what stayed in Photos.
    func deleteOriginals(_ identifiers: [String]) async -> OriginalDeleteOutcome {
        var outcome = OriginalDeleteOutcome()
        guard !identifiers.isEmpty else { return outcome }

        guard access().canReadLibrary else {
            outcome.unavailable = identifiers
            outcome.errorMessage = "MyVault is not allowed to change your Photos library."
            return outcome
        }

        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

        let found = Set(assets.map(\.localIdentifier))
        outcome.unavailable = identifiers.filter { !found.contains($0) }
        guard !assets.isEmpty else { return outcome }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            outcome.deleted = assets.map(\.localIdentifier)
        } catch {
            outcome.failed = assets.map(\.localIdentifier)
            outcome.errorMessage = "Photos refused to remove the originals, so they are still in your library."
        }
        return outcome
    }

    // MARK: - Saving exports

    /// Exports decrypted media back to the user's Photos library. Uses the
    /// Add-only permission, which is the correct level for creating new assets and
    /// does not grant read access to the rest of the library.
    func export(data: Data, isVideo: Bool) async throws {
        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await requestAddOnlyAuthorization()
        }
        guard status == .authorized || status == .limited else { throw VaultError.ioError }

        // The plaintext file lives in scratch space (complete protection, excluded
        // from backup) and is removed as soon as Photos has copied it.
        let extensionHint = MediaSniff.sniff(data)?.fileExtension
            ?? MediaSniff.fileExtension(forMediaType: isVideo ? "video" : "photo")
        let directory = try SecureScratch.makeDirectory(prefix: "export")
        defer { SecureScratch.removeDirectory(directory) }

        if isVideo {
            let url = try SecureScratch.write(data, named: "export.\(extensionHint)", in: directory)
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
