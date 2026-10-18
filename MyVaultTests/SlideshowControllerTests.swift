import XCTest
@testable import MyVault

/// Slideshow playback rules.
///
/// The controller is deliberately free of SwiftUI so the behaviour that matters most
/// can be tested directly: playback must never outlive the view that owns it.
@MainActor
final class SlideshowControllerTests: XCTestCase {

    // MARK: - Starting

    func testStartFromAllPhotos() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 10, index: 0)

        XCTAssertTrue(controller.canShow)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.count, 10)
        XCTAssertEqual(controller.index, 0)
        XCTAssertEqual(controller.indexText, "1 of 10")
    }

    func testStartFromAlbumMidCollection() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 4, index: 2)
        XCTAssertEqual(controller.index, 2)
        XCTAssertEqual(controller.indexText, "3 of 4")
    }

    func testStartIndexIsClamped() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 3, index: 99)
        XCTAssertEqual(controller.index, 2, "an out-of-range start must not point past the end")

        controller.start(count: 3, index: -5)
        XCTAssertEqual(controller.index, 0)
    }

    func testEmptyCollectionDoesNotPlay() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 0, index: 0)

        XCTAssertFalse(controller.canShow)
        XCTAssertFalse(controller.isPlaying, "an empty album must not start a running clock")
        XCTAssertEqual(controller.indexText, "")
    }

    func testSingleItemShowsButDoesNotAutoAdvance() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 1, index: 0)

        XCTAssertTrue(controller.canShow)
        XCTAssertFalse(controller.isPlaying, "there is nothing to advance to")
    }

    // MARK: - Pause / resume

    func testPauseAndResume() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 5, index: 0)

        controller.togglePlayback()
        XCTAssertFalse(controller.isPlaying)

        controller.togglePlayback()
        XCTAssertTrue(controller.isPlaying)
    }

    func testResumeOnLastSlideStartsOver() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 3, index: 2)
        controller.pause()
        controller.togglePlayback()

        XCTAssertEqual(controller.index, 0, "play from the final slide should wrap to the start")
        XCTAssertTrue(controller.isPlaying)
    }

    // MARK: - Navigation

    func testNextAndPrevious() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 3, index: 0)

        controller.next()
        XCTAssertEqual(controller.index, 1)
        controller.next()
        XCTAssertEqual(controller.index, 2)
        controller.next()
        XCTAssertEqual(controller.index, 0, "next wraps so the show keeps running")

        controller.previous()
        XCTAssertEqual(controller.index, 2, "previous wraps backwards")
        controller.previous()
        XCTAssertEqual(controller.index, 1)
    }

    // MARK: - The clock

    func testAwaitAdvanceMovesOnAfterTheDelay() async {
        let controller = SlideshowController(speed: .fast)
        controller.start(count: 3, index: 0)

        // Run the clock briefly and cancel, exactly as the view's `task` does on
        // dismissal.
        let task = Task { await controller.awaitAdvance() }
        try? await Task.sleep(nanoseconds: 2_400_000_000)
        task.cancel()
        _ = await task.value

        XCTAssertGreaterThanOrEqual(controller.index, 1, "the show should have advanced at least once")
        XCTAssertLessThanOrEqual(controller.index, 2)
    }

    func testPausedShowDoesNotAdvance() async {
        let controller = SlideshowController(speed: .fast)
        controller.start(count: 4, index: 0)
        controller.pause()

        let task = Task { await controller.awaitAdvance() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = await task.value

        XCTAssertEqual(controller.index, 0, "a paused slideshow must hold its slide")
    }

    func testNavigationDuringASleepRestartsTheWait() async {
        let controller = SlideshowController(speed: .fast)
        controller.start(count: 5, index: 0)

        let task = Task { await controller.awaitAdvance() }
        // The user jumps to the last slide well inside the 2 s window.
        try? await Task.sleep(nanoseconds: 300_000_000)
        controller.go(to: 4)
        try? await Task.sleep(nanoseconds: 400_000_000)
        task.cancel()
        _ = await task.value

        XCTAssertEqual(controller.index, 4, "the slide the user chose must not be skipped")
    }

    // MARK: - Cancellation

    func testStopEndsPlayback() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 6, index: 0)
        controller.stop()

        XCTAssertFalse(controller.isPlaying)
    }

    func testAwaitAdvanceReturnsImmediatelyWhenStopped() async {
        let controller = SlideshowController(speed: .slow)
        controller.start(count: 6, index: 0)
        controller.stop()

        // If this did not return promptly the test would wait out the 8 s slide.
        let task = Task { await controller.awaitAdvance() }
        let result = await task.result
        XCTAssertEqual(try? result.get(), true)
    }

    func testAwaitAdvanceReportsCancellation() async {
        let controller = SlideshowController(speed: .slow)
        controller.start(count: 6, index: 0)

        let task = Task { await controller.awaitAdvance() }
        task.cancel()
        let result = await task.result
        XCTAssertEqual(try? result.get(), false, "cancellation must be reported to the caller")
    }

    // MARK: - Collection changes

    func testRemovingAnEarlierItemShiftsTheIndex() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 5, index: 3)
        controller.collectionChanged(newCount: 4, removedIndex: 1)

        XCTAssertEqual(controller.index, 2, "the same photo should stay on screen")
    }

    func testRemovingTheVisibleItemIsReported() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 4, index: 1)
        controller.collectionChanged(newCount: 3, removedIndex: 1)

        XCTAssertEqual(controller.index, 1)
        XCTAssertNotNil(controller.unavailableNotice)
    }

    func testRemovingEverythingStopsTheShow() {
        let controller = SlideshowController(speed: .normal)
        controller.start(count: 2, index: 0)
        controller.collectionChanged(newCount: 0, removedIndex: 0)

        XCTAssertFalse(controller.canShow)
        XCTAssertFalse(controller.isPlaying)
    }

    // MARK: - Speed

    func testSpeedIsPersisted() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: SlideSpeed.defaultsKey)
        defer {
            if let original { defaults.set(original, forKey: SlideSpeed.defaultsKey) }
            else { defaults.removeObject(forKey: SlideSpeed.defaultsKey) }
        }

        let controller = SlideshowController(speed: .normal)
        controller.setSpeed(.fast)

        XCTAssertEqual(controller.speed, .fast)
        XCTAssertEqual(defaults.string(forKey: SlideSpeed.defaultsKey), SlideSpeed.fast.rawValue)
        XCTAssertEqual(SlideSpeed.saved, .fast)
    }

    func testSpeedsAreWithinTheRequestedRange() {
        XCTAssertGreaterThanOrEqual(SlideSpeed.fast.seconds, 2)
        XCTAssertLessThanOrEqual(SlideSpeed.slow.seconds, 8)
        // The default is the "3–5 seconds" the feature asks for.
        XCTAssertTrue((3.0...5.0).contains(SlideSpeed.normal.seconds))
    }
}
