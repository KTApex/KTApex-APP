import Foundation
import CoreTransferable
import PhotosUI
import UniformTypeIdentifiers

/// A `Transferable` that receives a picked item as a **file**.
///
/// `PhotosPickerItem.loadTransferable(type: Data.self)` materialises the whole
/// asset in memory, which for a long 4K video means several gigabytes of peak
/// footprint before the vault gets a chance to encrypt anything. Requesting a file
/// representation lets the system hand over a URL instead, and the bytes are then
/// read exactly once. The representation is copied into scratch space because the
/// URL the system provides is only valid for the duration of the importing closure.
struct PickedMediaFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            PickedMediaFile(url: try Self.adopt(received.file, fileExtension: "mov"))
        }
        FileRepresentation(importedContentType: .image) { received in
            PickedMediaFile(url: try Self.adopt(received.file, fileExtension: "img"))
        }
    }

    private static func adopt(_ source: URL, fileExtension: String) throws -> URL {
        let directory = try SecureScratch.makeDirectory(prefix: "pick")
        let target = directory.appendingPathComponent("payload.\(fileExtension)")
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            SecureScratch.removeDirectory(directory)
            throw error
        }
        return target
    }
}

/// Turns `PhotosPickerItem`s into vault import payloads.
enum PickedMediaLoader {

    /// Reads one item's bytes plus whatever the Photos library can tell us about
    /// the original (real file name, true capture date).
    ///
    /// Returns `nil` only when both transfer strategies fail, which the caller
    /// reports as a failed item — never as a silent skip.
    static func payload(for item: PhotosPickerItem) async -> ImportPayload? {
        let assetIdentifier = item.itemIdentifier
        let info = assetIdentifier.flatMap { PhotoLibraryService.shared.info(forAssetIdentifier: $0) }

        // Preferred path: the system writes the original bytes to a file we copy
        // into scratch space, so nothing is decoded, re-encoded or duplicated.
        if let file = try? await item.loadTransferable(type: PickedMediaFile.self) {
            defer { SecureScratch.removeDirectory(file.url.deletingLastPathComponent()) }
            // Deliberately not memory-mapped: the scratch file is deleted on the
            // next line, and a mapped buffer would outlive its backing file.
            if let data = try? Data(contentsOf: file.url), !data.isEmpty {
                return ImportPayload(
                    data: data,
                    assetIdentifier: assetIdentifier,
                    suggestedFileName: info?.filename,
                    capturedAt: info?.capturedAt
                )
            }
        }

        // Fallback: the in-memory transfer, which works even when the file
        // representation is unavailable for a particular asset.
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { return nil }
        return ImportPayload(
            data: data,
            assetIdentifier: assetIdentifier,
            suggestedFileName: info?.filename,
            capturedAt: info?.capturedAt
        )
    }
}
