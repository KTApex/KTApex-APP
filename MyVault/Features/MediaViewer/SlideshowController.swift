import SwiftUI

/// Slideshow speed. Stored as a raw value so the choice persists.
enum SlideSpeed: String, CaseIterable, Identifiable {
    case slow, normal, fast

    var id: String { rawValue }

    /// Time each photo stays on screen before advancing.
    var seconds: Double {
        switch self {
        case .slow: return 8
        case .normal: return 4
        case .fast: return 2
        }
    }

    var title: String {
        switch self {
        case .slow: return "Slow (8s)"
        case .normal: return "Normal (4s)"
        case .fast: return "Fast (2s)"
        }
    }

    static let defaultsKey = "mv.slideshowSpeed"

    /// Last choice, falling back to the 4-second default.
    static var saved: SlideSpeed {
        SlideSpeed(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .normal
    }
}

/// Drives the slideshow.
///
/// Deliberately *not* a `Timer`. A repeating timer is the classic way to leave a
/// loop running after the slideshow has closed, and it cannot be cancelled mid-tick.
/// Instead the owning view runs exactly one `task` that awaits a sleep for the
/// current slide, and SwiftUI cancels it the moment the view disappears. The
/// properties here only describe intent; `awaitAdvance()` performs it.
@MainActor
final class SlideshowController: ObservableObject {

    @Published private(set) var isPlaying = false
    /// Index to display. Owned here so pausing holds the current slide.
    @Published private(set) var index = 0
    @Published private(set) var count = 0

    /// Set when the collection lost the item that was on screen.
    @Published private(set) var unavailableNotice: String?

    private(set) var speed: SlideSpeed

    /// Bumped whenever navigation happens, so a sleeping `awaitAdvance()` can tell
    /// that the user moved on and restart its wait instead of advancing on top of
    /// the slide they just chose.
    private var tick = 0

    init(speed: SlideSpeed = .saved) {
        self.speed = speed
    }

    var canShow: Bool { count > 0 }
    var indexText: String { count > 0 ? "\(index + 1) of \(count)" : "" }

    // MARK: - Lifecycle

    /// Starts (or restarts) playback over a collection of `count` items.
    ///
    /// An empty collection is not an error: the controller reports `canShow == false`
    /// and the view shows its empty state instead of a black screen with a running
    /// clock. A single item is shown but not auto-advanced, because there is nothing
    /// to advance to.
    func start(count: Int, index: Int = 0) {
        self.count = max(0, count)
        self.index = self.count == 0 ? 0 : min(max(0, index), self.count - 1)
        unavailableNotice = nil
        isPlaying = self.count > 1
        tick += 1
    }

    /// Stops everything. Called on dismiss and whenever the vault locks, so no work
    /// continues and no further slide is requested.
    func stop() {
        isPlaying = false
        unavailableNotice = nil
        tick += 1
    }

    func setSpeed(_ newSpeed: SlideSpeed) {
        speed = newSpeed
        UserDefaults.standard.set(newSpeed.rawValue, forKey: SlideSpeed.defaultsKey)
        // Takes effect from the next slide so the current photo is not cut short by
        // the user opening the settings sheet.
        tick += 1
    }

    // MARK: - Playback

    func togglePlayback() {
        guard canShow else { return }
        // Paused on the final slide, pressing play should start over rather than sit
        // on the last photo forever.
        if !isPlaying && index == count - 1 { index = 0 }
        isPlaying.toggle()
        tick += 1
    }

    func pause() { isPlaying = false; tick += 1 }

    /// Advances to the next slide, wrapping to the start so an open slideshow keeps
    /// running instead of stopping on the last photo.
    func next() {
        guard canShow else { return }
        index = (index + 1) % count
        unavailableNotice = nil
        tick += 1
    }

    func previous() {
        guard canShow else { return }
        index = (index - 1 + count) % count
        unavailableNotice = nil
        tick += 1
    }

    func go(to newIndex: Int) {
        guard canShow else { return }
        index = min(max(0, newIndex), count - 1)
        unavailableNotice = nil
        tick += 1
    }

    /// The collection shrank (an item was trashed mid-show).
    ///
    /// `removedIndex` is the position that disappeared. Positions after it shift
    /// down by one; when the visible slide itself went away the show holds its place
    /// and reports it, rather than silently jumping to an unrelated photo.
    func collectionChanged(newCount: Int, removedIndex: Int?) {
        let previousCount = count
        count = max(0, newCount)
        guard count > 0 else {
            stop()
            return
        }
        if let removedIndex, removedIndex < index {
            index -= 1
        } else if let removedIndex, removedIndex == index {
            unavailableNotice = "That item is no longer available."
        }
        index = min(max(0, index), count - 1)
        if count <= 1 { isPlaying = false }
        if previousCount != count { tick += 1 }
    }

    /// Suspends until the current slide has been on screen for the configured
    /// duration, then advances.
    ///
    /// This is the whole clock. The view calls it from a single `task`; leaving the
    /// view cancels the sleep, so nothing can tick afterwards. Returns `false` when
    /// cancelled, and the caller should stop looping.
    func awaitAdvance() async -> Bool {
        while true {
            guard isPlaying, count > 1 else { return true }
            let startTick = tick
            let startIndex = index
            let delay = speed.seconds
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                // Cancelled: the view is going away.
                return false
            }
            // The user navigated, paused, or the collection changed while we slept.
            // Re-evaluate rather than advancing a slide they just left or paused on.
            guard isPlaying, count > 1, tick == startTick, index == startIndex else { continue }
            next()
        }
    }
}
