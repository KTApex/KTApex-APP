import Foundation
import SwiftUI
import SwiftData
import PhotosUI

/// Drives Photos → Vault imports and the removal of Photos originals.
///
/// The ordering below **is** the safety property the flow depends on:
///
/// 1. bytes are read, sniffed and encrypted,
/// 2. the ciphertext is read back and hash-verified,
/// 3. the SwiftData row is persisted,
/// 4. *only then* is the asset offered for removal, and only after the user confirms.
///
/// If any step fails the item is never offered for removal, the orphaned
/// ciphertext is deleted, and the Photos original is left untouched. Nothing in
/// this type ever deletes vault data.
@MainActor
final class ImportCoordinator: ObservableObject {

    enum Stage: Equatable {
        case idle
        case working(label: String, completed: Int, total: Int)

        var fraction: Double? {
            guard case let .working(_, completed, total) = self, total > 0 else { return nil }
            return min(max(Double(completed) / Double(total), 0), 1)
        }
    }

    struct Summary: Equatable {
        var imported = 0
        var duplicates = 0
        var failed = 0
        var skipped = 0
        var firstErrorMessage: String?
    }

    /// An action the user can take straight from a notice.
    enum NoticeAction: Equatable {
        case requestPhotosAccess
        case openSystemSettings
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
        var isError: Bool
        var action: NoticeAction?
        var actionTitle: String? {
            switch action {
            case .requestPhotosAccess: return "Allow Photos Access"
            case .openSystemSettings: return "Open Settings"
            case nil: return nil
            }
        }
    }

    struct RemovalRequest: Identifiable, Equatable {
        let id = UUID()
        var assetIdentifiers: [String]
        /// True when Photos access is limited, so only the selected items can go.
        var limitedAccess: Bool
        var count: Int { assetIdentifiers.count }
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var summary: Summary?
    @Published var removalRequest: RemovalRequest?
    @Published var notice: Notice?

    private var cancelRequested = false
    /// Identifiers from the most recent verified batch, so the permission alert can
    /// offer removal once access is granted.
    private var pendingRemovalIdentifiers: [String] = []

    var isWorking: Bool { stage != .idle }
    var workingLabel: String {
        if case let .working(label, _, _) = stage { return label }
        return ""
    }
    var progress: Double? { stage.fraction }
    var canCancel: Bool { isWorking && !cancelRequested }

    // MARK: - Import

    /// Requests Photos access *before* the picker is shown.
    ///
    /// Without read access the picker cannot report asset identifiers, which is the
    /// only handle the app has for removing an original later. Asking up front is
    /// what makes the verified-removal offer possible at all.
    func prepareForImport() async {
        guard PhotoLibraryService.shared.access() == .notDetermined else { return }
        _ = await PhotoLibraryService.shared.requestAuthorization()
    }

    func start(_ items: [PhotosPickerItem], context: ModelContext, album: VaultAlbum?) {
        guard !items.isEmpty, !isWorking else { return }
        cancelRequested = false
        summary = nil
        notice = nil
        stage = .working(label: "Reading from Photos", completed: 0, total: items.count)
        Task { await run(items, context: context, album: album) }
    }

    /// Stops after the current item. Everything already verified stays in the vault.
    func cancel() {
        guard isWorking else { return }
        cancelRequested = true
        if case let .working(_, completed, total) = stage {
            stage = .working(label: "Finishing the current item…", completed: completed, total: total)
        }
    }

    private func run(_ items: [PhotosPickerItem], context: ModelContext, album: VaultAlbum?) async {
        var result = Summary()
        var verifiedAssets: [String] = []
        var seen = Self.existingHashes(in: context)
        let total = items.count

        for (index, item) in items.enumerated() {
            if cancelRequested {
                result.skipped = total - index
                break
            }
            stage = .working(label: "Reading from Photos", completed: index, total: total)

            guard let payload = await PickedMediaLoader.payload(for: item) else {
                result.failed += 1
                if result.firstErrorMessage == nil {
                    result.firstErrorMessage = "One item could not be read from Photos. It was left untouched."
                }
                continue
            }

            stage = .working(label: "Encrypting and verifying", completed: index, total: total)
            let outcome = await VaultImportService.shared.importItem(payload, seenHashes: seen)

            switch outcome.status {
            case .imported:
                seen.insert(outcome.contentHash)
                if persist(outcome, context: context, album: album) {
                    result.imported += 1
                    if let asset = outcome.assetIdentifier { verifiedAssets.append(asset) }
                } else {
                    // Persisting failed, so the row does not exist: the ciphertext is
                    // an orphan and the original must not be offered for removal.
                    VaultStorageService.shared.delete(fileName: outcome.storedName)
                    result.failed += 1
                    if result.firstErrorMessage == nil {
                        result.firstErrorMessage = "Your vault could not save the new item, so the Photos original was kept."
                    }
                }
            case .duplicate:
                result.duplicates += 1
            case .failed:
                result.failed += 1
                if result.firstErrorMessage == nil { result.firstErrorMessage = outcome.errorMessage }
            }

            stage = .working(label: "Encrypting and verifying", completed: index + 1, total: total)
        }

        summary = result
        stage = .idle
        if result.imported > 0 { Haptics.success() } else if result.failed > 0 { Haptics.error() } else { Haptics.tap() }

        if !offerRemoval(for: verifiedAssets) {
            notice = Self.summaryNotice(result)
        }
    }

    private func persist(_ result: ImportItemResult, context: ModelContext, album: VaultAlbum?) -> Bool {
        let media = VaultMedia(
            fileName: result.fileName,
            encryptedFileName: result.storedName,
            mediaType: result.mediaType,
            fileSize: result.fileSize,
            contentHash: result.contentHash
        )
        media.width = result.width
        media.height = result.height
        media.duration = result.duration
        media.album = album
        // Real capture date so the gallery groups by when the moment happened, not
        // by when it was imported. Never fabricated: falls back to now, and a
        // nonsensical future date is clamped.
        if let capturedAt = result.capturedAt { media.createdAt = min(capturedAt, Date()) }
        context.insert(media)
        do {
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }

    private static func existingHashes(in context: ModelContext) -> Set<String> {
        guard let items = try? context.fetch(FetchDescriptor<VaultMedia>()) else { return [] }
        return Set(items.map(\.contentHash).filter { !$0.isEmpty })
    }

    // MARK: - Offering / performing original removal

    /// Returns true when the caller should *not* also present a summary notice,
    /// because a removal confirmation (or a permission notice) is on screen instead.
    private func offerRemoval(for assets: [String]) -> Bool {
        pendingRemovalIdentifiers = assets
        let access = PhotoLibraryService.shared.access()

        guard !assets.isEmpty else {
            // Media is safely in the vault but nothing can be removed — because the
            // library was never readable, so the picker returned no identifiers.
            guard !access.canReadLibrary else { return false }
            notice = Notice(
                title: "Saved to your vault",
                message: "Your encrypted \(summary?.imported == 1 ? "copy is" : "copies are") safe. \(access.explanation)",
                isError: false,
                action: access == .denied ? .openSystemSettings : .requestPhotosAccess
            )
            return true
        }

        removalRequest = RemovalRequest(assetIdentifiers: assets, limitedAccess: access == .limited)
        return true
    }

    /// The user confirmed: remove exactly the assets whose vault copies verified.
    func confirmRemoval() {
        guard let request = removalRequest else { return }
        removalRequest = nil
        stage = .working(label: "Removing originals from Photos", completed: 0, total: request.assetIdentifiers.count)
        Task {
            let outcome = await PhotoLibraryService.shared.deleteOriginals(request.assetIdentifiers)
            stage = .idle
            pendingRemovalIdentifiers = []
            if outcome.allDeleted {
                Haptics.success()
                let count = outcome.deleted.count
                notice = Notice(
                    title: "Removed from Photos",
                    message: "\(count) \(count == 1 ? "item was" : "items were") removed from your Photos library. Your encrypted \(count == 1 ? "copy is" : "copies are") safe in the vault.",
                    isError: false
                )
            } else {
                Haptics.error()
                notice = Notice(title: "Kept the originals", message: Self.removalFailureMessage(outcome), isError: true)
            }
        }
    }

    /// The user declined (or dismissed) the removal prompt: nothing is deleted.
    func keepOriginals() {
        removalRequest = nil
        pendingRemovalIdentifiers = []
        Haptics.tap()
        notice = Notice(
            title: "Kept in Photos",
            message: "Your originals are still in Photos, and the encrypted vault copies were kept as well.",
            isError: false
        )
    }

    func requestPhotosAccess() {
        Task {
            let access = await PhotoLibraryService.shared.requestAuthorization()
            if access.canReadLibrary {
                notice = Notice(
                    title: "Photos access granted",
                    message: "Access is only used to read the media you pick and, after a verified import, to remove the original you choose. Imports from now on can offer to remove originals.",
                    isError: false
                )
            } else {
                notice = Notice(
                    title: "Originals kept in Photos",
                    message: access.explanation,
                    isError: true,
                    action: access == .denied ? .openSystemSettings : nil
                )
            }
        }
    }

    func performNoticeAction() {
        switch notice?.action {
        case .requestPhotosAccess: notice = nil; requestPhotosAccess()
        case .openSystemSettings: notice = nil; PhotoLibraryService.shared.openSettings()
        case nil: notice = nil
        }
    }

    func dismissNotice() { notice = nil }

    // MARK: - Messages

    private static func summaryNotice(_ summary: Summary) -> Notice {
        var parts: [String] = []
        if summary.imported > 0 {
            parts.append("\(summary.imported) \(summary.imported == 1 ? "item" : "items") encrypted and verified")
        }
        if summary.duplicates > 0 { parts.append("\(summary.duplicates) already in the vault") }
        if summary.failed > 0 { parts.append("\(summary.failed) could not be imported") }
        if summary.skipped > 0 { parts.append("\(summary.skipped) skipped") }

        guard !parts.isEmpty else {
            return Notice(title: "Nothing to import", message: "No items were selected.", isError: false)
        }
        var message = parts.joined(separator: " · ")
        if let error = summary.firstErrorMessage { message += "\n\n\(error)" }
        return Notice(
            title: summary.failed > 0 ? "Import finished with problems" : "Saved to your vault",
            message: message,
            isError: summary.failed > 0
        )
    }

    private static func removalFailureMessage(_ outcome: OriginalDeleteOutcome) -> String {
        var parts: [String] = []
        if !outcome.deleted.isEmpty { parts.append("\(outcome.deleted.count) removed") }
        if !outcome.failed.isEmpty { parts.append("\(outcome.failed.count) refused by Photos") }
        if !outcome.unavailable.isEmpty { parts.append("\(outcome.unavailable.count) not visible to MyVault") }
        let detail = parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
        return "The originals that could not be removed\(detail) are still in your Photos library. Nothing was deleted from your vault."
    }
}
