import Foundation
import UIKit
import AVFoundation
import ImageIO

/// In-memory cache of decrypted thumbnails.
///
/// Decrypted pixels exist here only while the vault is unlocked: `clear()` runs on
/// lock and on backgrounding, so nothing survives a lock. Three constraints shape
/// the design:
///
/// * full-resolution data is never cached — a cell asks for a pixel size and gets
///   a downsampled image,
/// * images are downsampled *during* decode (ImageIO thumbnailing) rather than
///   decoded at full size and then scaled, which is the difference between a few
///   hundred kilobytes and a few hundred megabytes of peak memory in a grid,
/// * a video thumbnail costs a full decrypt of the video, so only a bounded number
///   are produced at once, and only for videos small enough that the cost is
///   proportionate to showing one grid cell.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Videos larger than this keep a placeholder tile: decrypting hundreds of
    /// megabytes to draw a 200-point square would make the grid unusable.
    static let videoThumbnailByteLimit = 200 * 1024 * 1024

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let videoGate = AsyncGate(limit: 2)
    /// Bumped by `clear()`. A render that started before a lock must not write its
    /// decrypted pixels into the cache after the lock, so results from an older
    /// generation are discarded instead of stored.
    private var generation = 0

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    // MARK: - Public API

    /// Returns a thumbnail, generating it off the main actor when it is not cached.
    func thumbnail(for item: VaultMedia, pixelSize: CGFloat = 400) async -> UIImage? {
        let key = Self.cacheKey(mediaID: item.id, pixelSize: pixelSize)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        // Two cells showing the same item share one decrypt.
        if let existing = inFlight[key] { return await existing.value }

        // Everything the background work needs is read here: SwiftData models must
        // not be touched from another thread.
        let request = RenderRequest(
            fileName: item.encryptedFileName,
            isVideo: item.isVideo,
            fileSize: item.fileSize,
            pixelSize: pixelSize
        )
        let gate = videoGate
        let limit = Self.videoThumbnailByteLimit

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            if request.isVideo {
                guard request.fileSize <= limit else { return nil }
                await gate.acquire()
                let image = await Self.renderVideoThumbnail(request)
                await gate.release()
                return image
            }
            return await Self.renderImageThumbnail(request)
        }

        let startGeneration = generation
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        guard generation == startGeneration else { return nil }
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
        }
        return image
    }

    /// Cache hit only — never decrypts. Used for instant placeholder rendering.
    func cachedThumbnail(for item: VaultMedia, pixelSize: CGFloat = 400) -> UIImage? {
        cache.object(forKey: Self.cacheKey(mediaID: item.id, pixelSize: pixelSize) as NSString)
    }

    /// Called on lock and on backgrounding. Everything decrypted is dropped.
    func clear() {
        generation &+= 1
        cache.removeAllObjects()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Rendering (off the main actor)

    private struct RenderRequest: Sendable {
        let fileName: String
        let isVideo: Bool
        let fileSize: Int
        let pixelSize: CGFloat
    }

    private nonisolated static func renderImageThumbnail(_ request: RenderRequest) async -> UIImage? {
        guard let data = try? VaultStorageService.shared.loadDecrypted(fileName: request.fileName) else { return nil }
        if MediaSniff.isPDF(data), let pdfThumb = renderPDFThumbnail(data, maxPixelSize: request.pixelSize) {
            return pdfThumb
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: request.pixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        // Formats ImageIO will decode but not down-sample fall back to a plain decode.
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingThumbnail(of: CGSize(width: request.pixelSize, height: request.pixelSize))
    }

    private nonisolated static func renderPDFThumbnail(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { return nil }
        let pageRect = page.getBoxRect(.mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }
        let scale = min(maxPixelSize / pageRect.width, maxPixelSize / pageRect.height)
        let targetSize = CGSize(width: max(pageRect.width * scale, 1), height: max(pageRect.height * scale, 1))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: targetSize))
            ctx.cgContext.translateBy(x: 0, y: targetSize.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.drawPDFPage(page)
        }
    }

    private nonisolated static func renderVideoThumbnail(_ request: RenderRequest) async -> UIImage? {
        guard let directory = try? SecureScratch.makeDirectory(prefix: "thumb") else { return nil }
        defer { SecureScratch.removeDirectory(directory) }
        guard let data = try? VaultStorageService.shared.loadDecrypted(fileName: request.fileName),
              let url = try? SecureScratch.write(data, named: "video.mov", in: directory) else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: request.pixelSize, height: request.pixelSize)
        // A little tolerance lets the generator pick a nearby sync frame instead of
        // decoding from the start of the file.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let oneSecond = CMTime(seconds: 1, preferredTimescale: 600)
        if let frame = try? await generator.image(at: oneSecond) {
            return UIImage(cgImage: frame.image)
        }
        // Clips shorter than a second (or with a black opening frame) still deserve
        // a tile.
        if let first = try? await generator.image(at: .zero) {
            return UIImage(cgImage: first.image)
        }
        return nil
    }

    // MARK: - Keys

    /// Sizes are bucketed so a rotating device or an odd column width cannot fill
    /// the cache with near-identical entries.
    private static func cacheKey(mediaID: String, pixelSize: CGFloat) -> String {
        let bucket = max(100, Int((pixelSize / 100).rounded(.up)) * 100)
        return "\(mediaID)-\(bucket)"
    }

    private static func cost(of image: UIImage) -> Int {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return max(Int(pixels * 4), 1)
    }
}

/// Minimal async semaphore: limits how many expensive renders run at once without
/// blocking any thread.
actor AsyncGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available += 1
        }
    }
}
