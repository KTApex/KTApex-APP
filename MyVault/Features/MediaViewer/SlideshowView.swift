import SwiftUI

/// Full-screen slideshow over whatever collection the user was looking at — the
/// whole vault, an album, or a filtered view.
///
/// Security notes, because this screen shows decrypted pixels unattended:
///
/// * images come from `ThumbnailCache`, which decrypts off the main actor and holds
///   results only in memory — no plaintext is written to disk here at all,
/// * `ThumbnailCache.clear()` runs on lock and on backgrounding, and `RootView`
///   replaces this view with the lock screen, so nothing can be shown afterwards,
/// * the playback clock is a single cancellable `task`, so leaving the screen or
///   locking the vault ends all activity,
/// * only a small window of slides is kept decoded (`prefetchRadius`), never the
///   whole album, so a 500-photo slideshow does not accumulate 500 images.
struct SlideshowView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Snapshot of the collection, taken when the slideshow was requested, so a
    /// SwiftData change cannot reshuffle the order mid-show.
    let items: [VaultMedia]
    let startIndex: Int
    var title: String?

    @StateObject private var controller = SlideshowController()
    @State private var chromeVisible = true
    @State private var showingSpeed = false

    /// Slides to keep decoded around the current one. Each is a screen-sized image,
    /// so a wide window would be a memory spike for no visible benefit.
    private static let prefetchRadius = 1

    private var isLocked: Bool { !appState.isUnlocked }

    private var current: VaultMedia? {
        guard controller.index >= 0, controller.index < items.count else { return nil }
        return items[controller.index]
    }

    var body: some View {
        ZStack {
            MVColor.viewerBackground.ignoresSafeArea()

            if !controller.canShow {
                emptyState
            } else {
                slides
            }

            if chromeVisible && !isLocked {
                chrome
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        // The show is an unattended screen; it must never survive a lock, so it is
        // torn down the moment the vault locks, taking its decoded pixels with it.
        .onChange(of: isLocked) { _, locked in
            if locked { dismiss() }
        }
        // Leaving the app pauses rather than playing on behind the privacy shield.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.pause() }
        }
        .task {
            controller.start(count: items.count, index: startIndex)
            // The loop lives exactly as long as this view. `awaitAdvance` sleeps for
            // the current slide and only advances when nothing else changed; the task
            // is cancelled on dismiss, which is what stops playback.
            _ = await controller.awaitAdvance()
        }
        .onDisappear { controller.stop() }
        .sheet(isPresented: $showingSpeed) { speedSheet }
        .accessibilityIdentifier("slideshow.screen")
    }

    // MARK: - Slides

    private var slides: some View {
        ZStack {
            // The visible slide is cross-faded rather than paged: a slideshow should
            // not look like a swipe the user did not make.
            ForEach(visibleItems) { item in
                SlideshowImage(item: item, pixelSize: Self.pixelSize)
                    .opacity(item.id == current?.id ? 1 : 0)
                    .accessibilityHidden(item.id != current?.id)
            }

            if let notice = controller.unavailableNotice {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title2)
                    Text(notice).font(.callout).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(20)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: MVRadius.m))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: controller.index)
        .contentShape(Rectangle())
        // Tapping the photo shows/hides the controls, so the image is never
        // permanently covered.
        .onTapGesture { toggleChrome() }
        // A horizontal swipe is still honoured for people who expect it from the
        // viewer, and it restarts the timer for the slide they chose.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    Haptics.selection()
                    if value.translation.width < 0 { controller.next() } else { controller.previous() }
                }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("slideshow.slides")
        .accessibilityLabel(current.map(accessibilityLabel) ?? "Slideshow")
    }

    /// Current slide plus the prefetch window. Only these have a view, so only these
    /// hold decoded images in memory.
    private var visibleItems: [VaultMedia] {
        guard !items.isEmpty else { return [] }
        let lower = max(0, controller.index - Self.prefetchRadius)
        let upper = min(items.count - 1, controller.index + Self.prefetchRadius)
        return Array(items[lower...upper])
    }

    /// Screen-sized rather than full-resolution: a slideshow is watched, not
    /// examined at 100%, and this keeps a 48 MP original from being decoded whole.
    @MainActor
    private static var pixelSize: CGFloat {
        (UIScreen.main.bounds.width * 2).rounded()
    }

    private func accessibilityLabel(_ item: VaultMedia) -> String {
        var parts = [item.fileName.isEmpty ? (item.isVideo ? "Video" : "Photo") : item.fileName]
        parts.append("\(controller.index + 1) of \(items.count)")
        parts.append(controller.isPlaying ? "Playing" : "Paused")
        return parts.joined(separator: ", ")
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close slideshow")
            .accessibilityIdentifier("slideshow.close")

            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? "Slideshow")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if controller.canShow {
                    Text(controller.indexText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
            }

            Spacer(minLength: 0)

            Button { showingSpeed = true } label: {
                Image(systemName: "timer")
                    .font(.callout.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Slideshow speed")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        // Material over a near-black backdrop needs the dark variant to stay legible
        // in Light mode.
        .environment(\.colorScheme, .dark)
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            progressBar
            HStack(spacing: 32) {
                control("backward.fill", "Previous photo") {
                    Haptics.selection()
                    controller.previous()
                }
                .disabled(!controller.canShow)

                Button {
                    Haptics.tap()
                    controller.togglePlayback()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 58, height: 58)
                        .background(.white.opacity(0.2), in: Circle())
                }
                .disabled(!controller.canShow)
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("slideshow.playPause")

                control("forward.fill", "Next photo") {
                    Haptics.selection()
                    controller.next()
                }
                .disabled(!controller.canShow)
            }
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(label)
    }

    /// Thin line showing how far through the collection the show is. Decorative, so
    /// hidden from VoiceOver, which already announces "3 of 25".
    private var progressBar: some View {
        GeometryReader { proxy in
            let fraction = items.isEmpty ? 0 : CGFloat(controller.index + 1) / CGFloat(items.count)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.18))
                Rectangle()
                    .fill(.white.opacity(0.85))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 2)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 44))
            Text("Nothing to show").font(MVFont.title)
            Text("There are no photos or videos in this collection yet.")
                .font(MVFont.body)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("slideshow.empty")
    }

    private func toggleChrome() {
        Haptics.tap()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            chromeVisible.toggle()
        }
    }

    private var speedSheet: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(SlideSpeed.allCases) { option in
                        Button {
                            Haptics.selection()
                            controller.setSpeed(option)
                        } label: {
                            HStack {
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                if controller.speed == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("Photos advance automatically. Swipe left or right, or use the arrows, to move at your own pace.")
                }
            }
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSpeed = false } }
            }
        }
        .presentationDetents([.medium])
    }
}

/// One slideshow slide.
///
/// Loads through `ThumbnailCache` — the same generation-guarded, memory-only cache
/// the grid uses — instead of decrypting a full-resolution copy, so slideshow
/// playback cannot leave plaintext on disk or grow memory with collection size.
private struct SlideshowImage: View {
    let item: VaultMedia
    let pixelSize: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    // Fit, never fill: a slideshow must not crop a face off a portrait
                    // photo to fill a landscape screen.
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white.opacity(0.7))
            }
        }
        .task(id: item.id) {
            if let cached = ThumbnailCache.shared.cachedThumbnail(for: item, pixelSize: pixelSize) {
                image = cached
                return
            }
            let loaded = await ThumbnailCache.shared.thumbnail(for: item, pixelSize: pixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
