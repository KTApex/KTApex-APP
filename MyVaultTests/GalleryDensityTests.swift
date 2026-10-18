import XCTest
@testable import MyVault

/// Grid density: the control that has to behave the same on every device, and the
/// preference that has to survive a relaunch.
final class GalleryDensityTests: XCTestCase {

    func testColumnsAdaptToWidth() {
        // A 6.1" iPhone is ~390 pt wide, an SE ~375, a Pro Max ~430, landscape ~844.
        let standard = GalleryDensity.standard
        XCTAssertEqual(standard.columns(forWidth: 390), 4)
        XCTAssertEqual(standard.columns(forWidth: 375), 4)
        XCTAssertEqual(standard.columns(forWidth: 430), 4)
        XCTAssertGreaterThan(standard.columns(forWidth: 844), standard.columns(forWidth: 390),
                             "landscape must not stretch the same number of tiles")
    }

    func testDenserChoicesYieldMoreColumns() {
        let widths: [CGFloat] = [320, 390, 430, 844]
        for width in widths {
            let columns = GalleryDensity.ordered.map { $0.columns(forWidth: width) }
            for pair in zip(columns, columns.dropFirst()) {
                XCTAssertGreaterThanOrEqual(pair.0, pair.1,
                                            "compact must never have fewer columns than a larger size")
            }
        }
    }

    func testColumnCountIsClampedToUsableRange() {
        XCTAssertEqual(GalleryDensity.compact.columns(forWidth: 2000), 6, "upper clamp")
        XCTAssertEqual(GalleryDensity.large.columns(forWidth: 80), 2, "lower clamp")
        XCTAssertEqual(GalleryDensity.standard.columns(forWidth: 0), 3, "an unmeasured grid falls back")
    }

    func testSteppingStopsAtTheEnds() {
        XCTAssertEqual(GalleryDensity.compact.stepped(by: -1), .compact)
        XCTAssertEqual(GalleryDensity.large.stepped(by: 1), .large)
        XCTAssertEqual(GalleryDensity.standard.stepped(by: 1), .comfortable,
                       "spreading a pinch makes tiles larger, which is one step up")
        XCTAssertEqual(GalleryDensity.standard.stepped(by: -1), .compact)
    }

    func testThumbnailPixelsAreBounded() {
        XCTAssertEqual(GalleryDensity.thumbnailPixels(tileWidth: 100, displayScale: 3), 300)
        XCTAssertEqual(GalleryDensity.thumbnailPixels(tileWidth: 2000, displayScale: 3), 1200,
                       "never ask the cache to decode more than a tile can show")
        XCTAssertEqual(GalleryDensity.thumbnailPixels(tileWidth: 1, displayScale: 1), 200)
    }

    func testDensityIsPersisted() {
        let defaults = UserDefaults.standard
        let originalDensity = defaults.string(forKey: GalleryDensity.preferencesKey)
        let originalColumns = defaults.object(forKey: GalleryDensity.legacyColumnsKey) as? Int
        defer {
            if let originalDensity { defaults.set(originalDensity, forKey: GalleryDensity.preferencesKey) }
            else { defaults.removeObject(forKey: GalleryDensity.preferencesKey) }
            if let originalColumns { defaults.set(originalColumns, forKey: GalleryDensity.legacyColumnsKey) }
            else { defaults.removeObject(forKey: GalleryDensity.legacyColumnsKey) }
        }

        GalleryDensity.save(.comfortable)
        XCTAssertEqual(GalleryDensity.load(), .comfortable)
        // The legacy key is kept truthful for the backup manifest.
        XCTAssertEqual(defaults.object(forKey: GalleryDensity.legacyColumnsKey) as? Int,
                       GalleryDensity.comfortable.columns(forWidth: 390))
    }

    func testLegacyColumnPreferenceIsMigrated() {
        let defaults = UserDefaults.standard
        let originalDensity = defaults.string(forKey: GalleryDensity.preferencesKey)
        let originalColumns = defaults.object(forKey: GalleryDensity.legacyColumnsKey) as? Int
        defer {
            if let originalDensity { defaults.set(originalDensity, forKey: GalleryDensity.preferencesKey) }
            else { defaults.removeObject(forKey: GalleryDensity.preferencesKey) }
            if let originalColumns { defaults.set(originalColumns, forKey: GalleryDensity.legacyColumnsKey) }
            else { defaults.removeObject(forKey: GalleryDensity.legacyColumnsKey) }
        }

        defaults.removeObject(forKey: GalleryDensity.preferencesKey)
        defaults.set(5, forKey: GalleryDensity.legacyColumnsKey)
        XCTAssertEqual(GalleryDensity.load(), .compact,
                       "a 5-column grid should upgrade to the closest density, not reset")

        defaults.set(2, forKey: GalleryDensity.legacyColumnsKey)
        XCTAssertEqual(GalleryDensity.load(), .large)
    }
}
