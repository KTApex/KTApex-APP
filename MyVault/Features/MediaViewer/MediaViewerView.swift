import SwiftUI
import SwiftData
import AVKit
import UIKit

/// Full-screen viewer: swipe between items, pinch or double-tap to zoom, drag while
/// zoomed, native video playback, and the actions the vault supports (favorite,
/// share, album, save to Photos, info, trash).
///
/// Decryption happens off the main actor and every video is played from a
/// protected scratch file that is removed when the page goes away — the vault's
/// ciphertext is never handed to `AVPlayer` directly, and no plaintext outlives the
/// viewer.
struct MediaViewerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \VaultAlbum.createdAt) private var albums: [VaultAlbum]

    let items: [VaultMedia]
    let selectedID: String?

    @State private var index = 0
    @State private var showingInfo = false
    @State private var shareBundle: ShareService.Prepared?
    @State private var alertItem: ViewerAlert?

    /// Legacy convenience initializer used by album detail.
    init(item: VaultMedia) {
        self.items = [item]
        self.selectedID = item.id
    }

    init(items: [VaultMedia], selectedID: String?) {
        self.items = items
        self.selectedID = selectedID
    }

    struct ViewerAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    private var item: VaultMedia? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    var body: some View {
        // The black backdrop is applied *outside* the NavigationStack and ignores
        // the safe area, so it is the true bottom layer of the whole presentation.
        // The navigation bar then renders over it in its inline/dark form, which is
        // what makes the viewer look like an immersive surface rather than a grid
        // with a toolbar bolted on.
        NavigationStack {
            ZStack {
                if item == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text("This item is no longer available.")
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TabView(selection: $index) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { position, media in
                            MediaPageView(media: media, isActive: position == index)
                                .tag(position)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .accessibilityLabel("Media viewer")
                }
            }
            .navigationTitle(item?.fileName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarContent }
            .statusBarHidden(false)
            .sheet(isPresented: $showingInfo) { infoSheet }
            .alert(alertItem?.title ?? "", isPresented: alertBinding, presenting: alertItem) { _ in
                Button("OK", role: .cancel) { alertItem = nil }
            } message: { alert in
                Text(alert.message)
            }
            .vaultShareSheet(prepared: $shareBundle)
        }
        .background(MVColor.viewerBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { syncIndex() }
        .onChange(of: items.count) { _, _ in syncIndex() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
            }
            .tint(.white)
            .accessibilityLabel("Close viewer")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !albums.isEmpty {
                    Menu("Add to Album") {
                        ForEach(albums) { album in
                            Button(album.name) { assign(to: album) }
                        }
                    }
                    if item?.album != nil {
                        Button("Remove from Album") { assign(to: nil) }
                    }
                }
                Button { saveToPhotos() } label: { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                if let count = currentPositionText {
                    Text(count)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .tint(.white)
            .accessibilityLabel("More actions")
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if let item {
                Button { toggleFavorite(item) } label: {
                    Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                }
                .tint(item.isFavorite ? .red : .white)
                .accessibilityLabel(item.isFavorite ? "Remove from favorites" : "Add to favorites")

                Button { share(item) } label: { Image(systemName: "square.and.arrow.up") }
                    .tint(.white)
                    .accessibilityLabel("Share")

                Spacer()

                Button { showingInfo = true } label: { Image(systemName: "info.circle") }
                    .tint(.white)
                    .accessibilityLabel("Media information")

                Button { trash(item) } label: { Image(systemName: "trash") }
                    .tint(.white)
                    .accessibilityLabel("Move to Recently Deleted")
            }
        }
    }

    private var currentPositionText: String? {
        guard items.count > 1 else { return nil }
        return "\(index + 1) of \(items.count)"
    }

    // MARK: - Info

    private var infoSheet: some View {
        NavigationStack {
            List {
                if let item {
                    Section("Media") {
                        MVInfoRow(label: "Name", value: item.fileName)
                        MVInfoRow(label: "Type", value: item.isVideo ? "Video" : "Photo")
                        MVInfoRow(label: "Size", value: StorageService.formatted(item.fileSize))
                        if item.width > 0 && item.height > 0 {
                            MVInfoRow(label: "Dimensions", value: "\(item.width) × \(item.height)")
                        }
                        if item.isVideo && item.duration > 0 {
                            MVInfoRow(label: "Duration", value: GalleryThumbCell.durationText(item.duration))
                        }
                        MVInfoRow(label: "Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        MVInfoRow(label: "Favorite", value: item.isFavorite ? "Yes" : "No")
                        MVInfoRow(label: "Album", value: item.album?.name ?? "None")
                    }
                    Section {
                        MVInfoRow(label: "Encrypted file", value: item.encryptedFileName)
                        Text("Photos and videos are stored as AES-GCM ciphertext. Nothing here is uploaded anywhere.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("On this device")
                    }
                }
            }
            .navigationTitle("Information")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingInfo = false } }
            }
        }
    }

    // MARK: - Actions

    private func syncIndex() {
        guard !items.isEmpty else {
            dismiss()
            return
        }
        if let selectedID, let found = items.firstIndex(where: { $0.id == selectedID }) {
            index = found
        } else if index >= items.count {
            index = max(0, items.count - 1)
        }
    }

    private func toggleFavorite(_ item: VaultMedia) {
        item.isFavorite.toggle()
        context.saveReporting { _ in
            alertItem = ViewerAlert(title: "Not saved", message: "The favorite change could not be saved.")
        }
        Haptics.selection()
    }

    private func assign(to album: VaultAlbum?) {
        guard let item else { return }
        item.album = album
        context.saveReporting { _ in
            alertItem = ViewerAlert(title: "Not saved", message: "The album change could not be saved.")
        }
        Haptics.success()
    }

    private func share(_ item: VaultMedia) {
        Task {
            do {
                shareBundle = try await ShareService.shared.prepare([item])
            } catch {
                Haptics.error()
                alertItem = ViewerAlert(
                    title: "Sharing failed",
                    message: error.localizedDescription + " Nothing was removed from your vault."
                )
            }
        }
    }

    private func saveToPhotos() {
        guard let item else { return }
        Task {
            do {
                let data = try VaultStorageService.shared.loadDecrypted(fileName: item.encryptedFileName)
                try await PhotoLibraryService.shared.export(data: data, isVideo: item.isVideo)
                Haptics.success()
                alertItem = ViewerAlert(title: "Saved to Photos", message: "A copy was added to your Photos library. The encrypted vault copy is unchanged.")
            } catch {
                Haptics.error()
                alertItem = ViewerAlert(
                    title: "Could not save",
                    message: "MyVault could not add this to your Photos library. Check Photos permission in Settings."
                )
            }
        }
    }

    private func trash(_ item: VaultMedia) {
        item.isInTrash = true
        item.trashedAt = Date()
        context.saveReporting { _ in
            alertItem = ViewerAlert(title: "Not deleted", message: "The item could not be moved to Recently Deleted, so it is still in your vault.")
        }
        Haptics.success()
        if items.count <= 1 {
            dismiss()
        } else {
            index = min(index, items.count - 2)
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertItem != nil }, set: { if !$0 { alertItem = nil } })
    }
}

/// One page of the viewer: a zoomable photo or a playing video.
private struct MediaPageView: View {
    let media: VaultMedia
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Loaded {
        case image(UIImage)
        case video(URL)
        case failed
    }

    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loadFailure: String?
    @State private var scratchDirectory: URL?

    @State private var scale: CGFloat = 1
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnificationGesture, including: .all)
                        // While zoomed the image owns the drag (so panning works and
                        // paging is suspended); at 1× the drag is disabled so the
                        // pager keeps handling swipes.
                        .gesture(dragGesture, including: scale > 1 ? .all : .subviews)
                        .onTapGesture(count: 2) { toggleZoom() }
                        .accessibilityLabel(media.isVideo ? "Video" : "Photo")
                } else if let player {
                    VideoPlayer(player: player)
                } else if let loadFailure {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(loadFailure)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            // The page fills whatever the pager gives it; `scaledToFit` on the media
            // keeps its aspect ratio, so the image is centred without being
            // double-constrained by per-branch frames.
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .task(id: media.id) { await load() }
        .onChange(of: isActive) { _, active in
            if !active { player?.pause() }
        }
        .onDisappear { cleanup() }
    }

    // MARK: - Gestures

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(settledScale * value.magnification, 1), 6)
            }
            .onEnded { _ in
                settledScale = scale
                if scale <= 1.01 { resetZoom(animated: true) }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { _ in settledOffset = offset }
    }

    private func toggleZoom() {
        Haptics.tap()
        if scale > 1 {
            resetZoom(animated: true)
        } else {
            let target: CGFloat = 2.5
            if reduceMotion {
                scale = target
                settledScale = target
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    scale = target
                    settledScale = target
                }
            }
        }
    }

    private func resetZoom(animated: Bool) {
        let apply = {
            scale = 1
            settledScale = 1
            offset = .zero
            settledOffset = .zero
        }
        if animated && !reduceMotion {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { apply() }
        } else {
            apply()
        }
    }

    // MARK: - Loading

    @MainActor
    private func load() async {
        guard image == nil, player == nil, loadFailure == nil else { return }
        guard let directory = try? SecureScratch.makeDirectory(prefix: "view") else {
            loadFailure = "This media could not be opened."
            return
        }
        scratchDirectory = directory

        let fileName = media.encryptedFileName
        let isVideo = media.isVideo
        let loaded = await Task.detached(priority: .userInitiated) { () -> Loaded in
            guard let data = try? VaultStorageService.shared.loadDecrypted(fileName: fileName) else { return .failed }
            if isVideo {
                let fileExtension = MediaSniff.sniff(data)?.fileExtension ?? "mov"
                guard let url = try? SecureScratch.write(data, named: "playback.\(fileExtension)", in: directory) else {
                    return .failed
                }
                return .video(url)
            }
            guard let decoded = UIImage(data: data) else { return .failed }
            return .image(decoded)
        }.value

        switch loaded {
        case .image(let decoded):
            image = decoded
        case .video(let url):
            player = AVPlayer(url: url)
        case .failed:
            loadFailure = media.isVideo
                ? "This video could not be decrypted."
                : "This photo could not be decrypted."
        }
    }

    private func cleanup() {
        player?.pause()
        player = nil
        if let scratchDirectory {
            SecureScratch.removeDirectory(scratchDirectory)
            self.scratchDirectory = nil
        }
    }
}
