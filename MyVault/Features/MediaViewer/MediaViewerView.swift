import SwiftUI
import AVKit

/// Full-screen viewer with swipe-to-navigate, pinch/double-tap zoom, video playback,
/// favorite, share/export, info, and delete (moves to trash).
struct MediaViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    let items: [VaultMedia]
    let selectedID: String?

    @State private var index: Int = 0
    @State private var showingInfo = false
    @State private var showingShare = false
    @State private var exportedURL: URL?

    /// Legacy convenience initializer used by album detail.
    init(item: VaultMedia) {
        self.items = [item]
        self.selectedID = item.id
    }

    init(items: [VaultMedia], selectedID: String?) {
        self.items = items
        self.selectedID = selectedID
    }

    private var item: VaultMedia? {
        guard index >= 0, index < items.count else { return nil }
        return items[index]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if item != nil {
                    TabView(selection: $index) {
                        ForEach(items.indices, id: \.self) { i in
                            MediaPageView(media: items[i])
                                .tag(i)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .ignoresSafeArea()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.tint(.white)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if let item {
                        Button { toggleFavorite(item) } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                        }.tint(.white)
                        Button { showingInfo = true } label: { Image(systemName: "info.circle") }.tint(.white)
                        Spacer()
                        Button { share(item) } label: { Image(systemName: "square.and.arrow.up") }.tint(.white)
                        Button(role: .destructive) { trash(item) } label: { Image(systemName: "trash") }.tint(.white)
                    }
                }
            }
            .alert("Media Info", isPresented: $showingInfo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(infoText)
            }
            .sheet(isPresented: $showingShare, onDismiss: cleanupExportedURL) {
                if let exportedURL {
                    ShareLink(item: exportedURL)
                        .presentationDetents([.medium])
                }
            }
        }
        .task { if let id = selectedID, let i = items.firstIndex(where: { $0.id == id }) { index = i } }
    }

    private var infoText: String {
        guard let item else { return "" }
        return "\(item.fileName)\n\(StorageService.formatted(item.fileSize))"
    }

    private func toggleFavorite(_ item: VaultMedia) {
        item.isFavorite.toggle()
        try? context.save()
        Haptics.selection()
    }

    private func share(_ item: VaultMedia) {
        guard let data = try? VaultStorageService.shared.loadDecrypted(fileName: item.encryptedFileName) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + (item.fileName.isEmpty ? item.id : item.fileName))
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        exportedURL = url
        showingShare = true
    }

    private func cleanupExportedURL() {
        if let url = exportedURL {
            try? FileManager.default.removeItem(at: url)
            exportedURL = nil
        }
    }

    private func trash(_ item: VaultMedia) {
        item.isInTrash = true
        item.trashedAt = Date()
        try? context.save()
        Haptics.success()
        dismiss()
    }
}

private struct MediaPageView: View {
    let media: VaultMedia
    @State private var image: UIImage?
    @State private var videoURL: URL?
    @State private var scale: CGFloat = 1
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable().scaledToFit()
                    .scaleEffect(scale)
                    .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) })
                    .onTapGesture(count: 2) {
                        withAnimation(.spring) { scale = scale > 1 ? 1 : 2.5 }
                        Haptics.tap()
                    }
            } else if let videoURL {
                VideoPlayer(player: AVPlayer(url: videoURL))
            } else if error != nil {
                Text(error ?? "Could not load media.").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: media.id) { await load() }
        .onDisappear { cleanupTempVideo() }
    }

    @MainActor
    private func load() async {
        guard image == nil, videoURL == nil else { return }
        do {
            let data = try VaultStorageService.shared.loadDecrypted(fileName: media.encryptedFileName)
            if media.isVideo {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                videoURL = url
            } else {
                guard let img = UIImage(data: data) else {
                    error = "This photo could not be decrypted."
                    return
                }
                image = img
            }
        } catch {
            let message = "This media could not be decrypted."
            self.error = message
        }
    }

    private func cleanupTempVideo() {
        if let url = videoURL {
            try? FileManager.default.removeItem(at: url)
            videoURL = nil
        }
    }
}

