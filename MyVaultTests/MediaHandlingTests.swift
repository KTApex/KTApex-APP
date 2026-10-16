import XCTest
import UIKit
@testable import MyVault

/// Sniffing and naming decide whether a share export is usable by the receiving
/// app and whether an import is trustworthy, so they get direct coverage with
/// byte fixtures rather than real user media.
final class MediaHandlingTests: XCTestCase {

    /// 1×1 PNG. A real, decodable image keeps the fixture independent of the
    /// simulator's image encoders.
    private let pngData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func jpegData(width: Int = 8, height: Int = 4) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    private func isoBaseMedia(brand: String) -> Data {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x20]
        bytes.append(contentsOf: Array("ftyp".utf8))
        bytes.append(contentsOf: Array(brand.utf8))
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return Data(bytes)
    }

    // MARK: - Sniffing

    func testJPEGIsDetectedAsJPEGImage() throws {
        let sniff = try XCTUnwrap(MediaSniff.sniff(try jpegData()))
        XCTAssertEqual(sniff.kind, .image)
        // Normalised from public.jpeg so share targets see the familiar spelling.
        XCTAssertEqual(sniff.fileExtension, "jpg")
    }

    func testPNGIsDetectedAsPNGImage() throws {
        let sniff = try XCTUnwrap(MediaSniff.sniff(pngData))
        XCTAssertEqual(sniff.kind, .image)
        XCTAssertEqual(sniff.fileExtension, "png")
    }

    func testMP4BrandIsDetectedAsVideo() {
        let sniff = MediaSniff.sniff(isoBaseMedia(brand: "isom"))
        XCTAssertEqual(sniff?.kind, .video)
        XCTAssertEqual(sniff?.fileExtension, "mp4")
    }

    func testQuickTimeBrandIsDetectedAsMOV() {
        let sniff = MediaSniff.sniff(isoBaseMedia(brand: "qt  "))
        XCTAssertEqual(sniff?.kind, .video)
        XCTAssertEqual(sniff?.fileExtension, "mov")
    }

    func testUnknownBytesAreRejected() {
        XCTAssertNil(MediaSniff.sniff(Data(repeating: 0x7A, count: 4096)))
    }

    func testEmptyDataIsRejected() {
        XCTAssertNil(MediaSniff.sniff(Data()))
    }

    func testTruncatedContainerHeaderIsRejected() {
        // "ftyp" but the brand does not fit: not enough bytes to be a real file.
        XCTAssertNil(MediaSniff.sniff(Data([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79])))
    }

    // MARK: - File names

    func testStemRemovesPathSeparatorsAndColons() {
        XCTAssertEqual(MediaFileName.stem("IMG 1234/56:78"), "IMG 1234-56-78")
    }

    func testStemNeutralisesTraversalAndHiddenNames() {
        let traversal = MediaFileName.stem("../../../etc/passwd")
        XCTAssertFalse(traversal.contains("/"))
        XCTAssertFalse(traversal.contains(".."))
        XCTAssertFalse(traversal.hasPrefix("."))

        let hidden = MediaFileName.stem(".secret")
        XCTAssertFalse(hidden.hasPrefix("."))
        XCTAssertEqual(hidden, "secret")
    }

    func testSanitizedNameKeepsOneExtension() {
        XCTAssertEqual(MediaFileName.sanitized("IMG_1234.HEIC", fileExtension: "heic"), "IMG_1234.heic")
    }

    func testSanitizedNameReplacesMismatchedExtension() {
        XCTAssertEqual(MediaFileName.sanitized("clip.mov", fileExtension: "mp4"), "clip.mp4")
    }

    func testSanitizedNameFallsBackWhenEverythingIsStripped() {
        XCTAssertEqual(MediaFileName.sanitized("///", fileExtension: "jpg"), "MyVault.jpg")
    }

    func testSanitizedNameIsLengthLimited() {
        let long = String(repeating: "a", count: 400)
        let name = MediaFileName.sanitized(long, fileExtension: "jpg")
        XCTAssertLessThanOrEqual(name.count, 85)
        XCTAssertTrue(name.hasSuffix(".jpg"))
    }

    func testGeneratedNameUsesCaptureDate() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 16
        components.hour = 15; components.minute = 45; components.second = 30
        let calendar = Calendar.current
        let date = calendar.date(from: components)!
        XCTAssertEqual(MediaFileName.generated(capturedAt: date, fileExtension: "heic"),
                       "MyVault_2026-10-16_15-45-30.heic")
    }

    func testResolveKeepsTheOriginalPhotosName() {
        let name = MediaFileName.resolve(suggested: "IMG_0001.HEIC", capturedAt: Date(), fileExtension: "heic")
        XCTAssertEqual(name, "IMG_0001.heic")
    }

    func testResolveFallsBackWhenNoNameIsAvailable() {
        let name = MediaFileName.resolve(suggested: "   ", capturedAt: nil, fileExtension: "mp4")
        XCTAssertTrue(name.hasPrefix("MyVault_"))
        XCTAssertTrue(name.hasSuffix(".mp4"))
    }
}
