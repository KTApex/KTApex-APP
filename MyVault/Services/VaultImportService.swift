import Foundation
import ImageIO
import AVFoundation

enum ImportItemStatus: Equatable { case imported, duplicate, failed }

/// One item's outcome.
///
/// An item is only ever `.imported` after its ciphertext has been written, read
/// back through the decrypt path and hash-matched against the plaintext, so a
/// `.imported` result with a non-empty `storedName` is a *verified* vault copy.
/// Only those items are eligible for removal from Apple Photos.
struct ImportItemResult: Equatable {
    var status: ImportItemStatus
    /// Photos asset identifier; nil when the app could not read the library
    /// (no permission) or the item did not come from Photos.
    var assetIdentifier: String?
    /// Encrypted vault file name — non-empty only for `.imported`.
    var storedName: String
    /// Clean, extension-bearing display name (safe to write to a file system).
    var fileName: String
    var mediaType: String
    var fileSize: Int
    var contentHash: String
    var width: Int
    var height: Int
    var duration: Double
    /// Real capture date when the library exposed one; nil when unknown.
    var capturedAt: Date?
    var errorMessage: String?

    static func failure(assetIdentifier: String?, fileName: String, fileSize: Int, hash: String, message: String) -> ImportItemResult {
        ImportItemResult(
            status: .failed, assetIdentifier: assetIdentifier, storedName: "", fileName: fileName,
            mediaType: "", fileSize: fileSize, contentHash: hash, width: 0, height: 0,
            duration: 0, capturedAt: nil, errorMessage: message
        )
    }
}

struct ImportOutcome {
    var results: [ImportItemResult]
    /// Assets whose vault copy verified. This is the only list the deletion
    /// confirmation may be built from.
    var verifiedAssetIdentifiers: [String] {
        results.compactMap { $0.status == .imported ? $0.assetIdentifier : nil }
    }
    var importedCount: Int { results.filter { $0.status == .imported }.count }
    var duplicateCount: Int { results.filter { $0.status == .duplicate }.count }
    var failedCount: Int { results.filter { $0.status == .failed }.count }
}

/// Bytes on their way into the vault, plus whatever the library could tell us
/// about where they came from.
struct ImportPayload {
    var data: Data
    var assetIdentifier: String?
    var suggestedFileName: String?
    var capturedAt: Date?
}

/// The single import pipeline: sniff → dedupe → encrypt → verify round-trip.
///
/// Deliberately free of SwiftData and PhotosUI so the whole path can be tested on
/// raw `Data`; the caller decides what to do with the results.
final class VaultImportService {
    static let shared = VaultImportService()
    private init() {}

    /// Import refuses anything above this size because the vault's AES-GCM layer
    /// seals a whole payload at once, so a multi-gigabyte file would be loaded
    /// into memory twice and the app would be killed by the OS mid-import.
    /// Refusing up front with a clear message is safer than an OOM crash.
    static let maxItemBytes = 1_024 * 1_024 * 1_024

    // MARK: - One item

    /// Imports a single payload.
    ///
    /// `seenHashes` must contain the content hashes of everything already in the
    /// vault; the result reports `.duplicate` instead of storing a second copy.
    func importItem(_ payload: ImportPayload, seenHashes: Set<String>) async -> ImportItemResult {
        let data = payload.data
        let hash = EncryptionService.sha256(data)
        let candidateExtension = MediaSniff.sniff(data)?.fileExtension ?? ""
        let name = MediaFileName.resolve(
            suggested: payload.suggestedFileName,
            capturedAt: payload.capturedAt,
            fileExtension: candidateExtension.isEmpty ? "bin" : candidateExtension
        )

        guard !data.isEmpty else {
            return .failure(assetIdentifier: payload.assetIdentifier, fileName: name, fileSize: 0,
                            hash: hash, message: "This item is empty, so there is nothing to import.")
        }
        guard data.count <= Self.maxItemBytes else {
            return .failure(assetIdentifier: payload.assetIdentifier, fileName: name, fileSize: data.count,
                            hash: hash, message: "This item is larger than 1 GB. Save it to Files first, then import a smaller version.")
        }
        guard !seenHashes.contains(hash) else {
            return ImportItemResult(
                status: .duplicate, assetIdentifier: payload.assetIdentifier, storedName: "", fileName: name,
                mediaType: "", fileSize: data.count, contentHash: hash, width: 0, height: 0,
                duration: 0, capturedAt: payload.capturedAt, errorMessage: nil
            )
        }
        // Media we cannot identify is refused rather than stored as an opaque blob:
        // a truncated or damaged pick must not silently become an unopenable row.
        guard let sniff = MediaSniff.sniff(data) else {
            return .failure(assetIdentifier: payload.assetIdentifier, fileName: name, fileSize: data.count,
                            hash: hash, message: "This item could not be read — it may be damaged or in a format MyVault cannot decode.")
        }

        var width = 0
        var height = 0
        var duration = 0.0
        switch sniff.kind {
        case .image:
            if let size = Self.imageDimensions(data) {
                width = size.width
                height = size.height
            }
        case .video:
            let meta = await Self.videoMetadata(data, fileExtension: sniff.fileExtension)
            // A missing duration is cosmetic and never blocks an import, but a file
            // that decodes to no tracks at all is not playable media — it is a
            // truncated or damaged download wearing a valid container header.
            guard meta.hasTracks else {
                return .failure(assetIdentifier: payload.assetIdentifier, fileName: name, fileSize: data.count,
                                hash: hash, message: "This video could not be read — it may be incomplete or damaged.")
            }
            duration = meta.duration
            width = meta.width
            height = meta.height
        }

        let storedName: String
        do {
            storedName = try VaultStorageService.shared.storeEncrypted(data: data)
        } catch {
            return .failure(assetIdentifier: payload.assetIdentifier, fileName: name, fileSize: data.count,
                            hash: hash, message: "This item could not be encrypted, so nothing was saved.")
        }

        // Verify through the real decrypt path before the item counts as imported.
        // A corrupt or truncated write must never leave a VaultMedia row (or a
        // deletion prompt) pointing at unusable data.
        guard VaultStorageService.shared.verify(fileName: storedName, matchesPlaintextHash: hash) else {
            VaultStorageService.shared.delete(fileName: storedName)
            return .failure(assetIdentifier: payload.assetIdentifier, fileName: name, fileSize: data.count,
                            hash: hash, message: "The encrypted copy could not be verified, so it was not saved.")
        }

        return ImportItemResult(
            status: .imported, assetIdentifier: payload.assetIdentifier, storedName: storedName,
            fileName: name, mediaType: sniff.kind.rawValue, fileSize: data.count, contentHash: hash,
            width: width, height: height, duration: duration, capturedAt: payload.capturedAt, errorMessage: nil
        )
    }

    // MARK: - Batch

    /// Imports several payloads, deduping against both the existing vault and the
    /// items earlier in the same batch.
    ///
    /// `isCancelled` is polled between items so a user can stop a long import; items
    /// already verified stay imported, and the rest are simply never started.
    func importBatch(
        _ payloads: [ImportPayload],
        existingHashes: Set<String>,
        isCancelled: @Sendable () -> Bool = { false },
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> ImportOutcome {
        guard !payloads.isEmpty else { return ImportOutcome(results: []) }
        var results: [ImportItemResult] = []
        var seen = existingHashes
        let total = payloads.count
        for (index, payload) in payloads.enumerated() {
            if isCancelled() { break }
            let result = await importItem(payload, seenHashes: seen)
            if result.status == .imported { seen.insert(result.contentHash) }
            results.append(result)
            progress?(Double(index + 1) / Double(total))
        }
        return ImportOutcome(results: results)
    }

    /// Convenience overload kept for callers that only have raw bytes.
    func importBatch(
        _ payloads: [(data: Data, assetIdentifier: String?)],
        existingHashes: Set<String>,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> ImportOutcome {
        let converted = payloads.map {
            ImportPayload(data: $0.data, assetIdentifier: $0.assetIdentifier, suggestedFileName: nil, capturedAt: nil)
        }
        return await importBatch(converted, existingHashes: existingHashes, progress: progress)
    }

    // MARK: - Metadata

    static func imageDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    struct VideoMetadata: Equatable {
        var duration: Double = 0
        var width: Int = 0
        var height: Int = 0
        var trackCount: Int = 0
        /// True when the file opened and reported at least the track containers
        /// we asked for, i.e. it is playable media rather than stray bytes.
        var hasTracks: Bool { trackCount > 0 }
    }

    /// Reads duration and pixel size from a probe file in scratch space. The probe
    /// is protected and removed before this returns, whatever happens.
    ///
    /// Metadata is best effort: a failure leaves the values at zero so the media
    /// still imports. Only `trackCount` is treated as a correctness signal.
    static func videoMetadata(_ data: Data, fileExtension: String) async -> VideoMetadata {
        var result = VideoMetadata()
        guard let directory = try? SecureScratch.makeDirectory(prefix: "probe") else { return result }
        defer { SecureScratch.removeDirectory(directory) }
        guard let url = try? SecureScratch.write(data, named: "probe.\(fileExtension)", in: directory) else { return result }

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = duration.seconds
            if seconds.isFinite, seconds > 0 { result.duration = seconds }
        }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        result.trackCount = videoTracks.count + audioTracks.count
        if let track = videoTracks.first, let size = try? await track.load(.naturalSize) {
            result.width = Int(abs(size.width.rounded()))
            result.height = Int(abs(size.height.rounded()))
        }
        return result
    }
}
