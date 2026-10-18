import SwiftUI
import SwiftData

/// One album's media, using the same grid, grouping and selection behaviour as the
/// main vault so the two screens never drift apart.
///
/// Every action here is album-scoped: "Remove from Album" detaches the label and
/// leaves the encrypted file untouched, and trashing still goes through the normal
/// 30-day Recently Deleted flow.
struct AlbumDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var appState: AppState
    @Query(sort: \VaultMedia.createdAt, order: .reverse) private var allMedia: [VaultMedia]
    let album: VaultAlbum

    @State private var sortOrder: GallerySort = .newest
    @State private var density: GalleryDensity = GalleryDensity.load()
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewerItem: VaultMedia?
    @State private var slideshowRequest: SlideshowRequest?
    @State private var shareBundle: ShareService.Prepared?
    @State private var alertMessage: String?
    @State private var showingAddPicker = false

    /// Membership is matched by stable ID across the whole library, so an item whose
    /// relationship object was re-created (after a relaunch or a restore) still
    /// appears here.
    private var items: [VaultMedia] {
        GalleryComposer.sort(AlbumEditor.items(in: album, from: allMedia), by: sortOrder)
    }

    private var sections: [GallerySection] {
        GalleryComposer.sections(items, grouping: .day)
    }

    private var selectedItems: [VaultMedia] {
        items.filter { selection.contains($0.id) }
    }

    /// Immutable snapshot handed to the slideshow cover.
    struct SlideshowRequest: Identifiable {
        let id = UUID()
        let items: [VaultMedia]
        let startIndex: Int
        let title: String
    }

    var body: some View {
        Group {
            if items.isEmpty {
                MVEmptyState(
                    symbol: "folder",
                    title: "Album is empty",
                    subtitle: "Add photos from your vault. They stay encrypted and are never copied.",
                    actionTitle: "Add Photos",
                    action: { showingAddPicker = true }
                )
            } else {
                GalleryGrid(
                    sections: sections,
                    density: density,
                    isSelecting: isSelecting,
                    selection: $selection,
                    onOpen: { viewerItem = $0 },
                    onToggleSelection: { toggleSelection($0) },
                    onDensityChange: { next in
                        density = next
                        GalleryDensity.save(next)
                    }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
        .navigationTitle("\(album.name) (\(items.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        // A full-screen viewer, matching the vault: a sheet would let the album
        // grid show around the media and would not own the screen.
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewerView(items: items, selectedID: item.id, title: album.name)
                .environmentObject(appState)
        }
        .fullScreenCover(item: $slideshowRequest) { request in
            SlideshowView(items: request.items, startIndex: request.startIndex, title: request.title)
        }
        .sheet(isPresented: $showingAddPicker) { addPhotosSheet }
        .vaultShareSheet(prepared: $shareBundle)
        .alert("Album", isPresented: alertBinding) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onChange(of: items.count) { _, _ in clampSelection() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if !isSelecting {
                Button { showingAddPicker = true } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add photos to album")
                .accessibilityIdentifier("album.addPhotos")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !items.isEmpty && !isSelecting {
                Button { startSlideshow() } label: {
                    Image(systemName: "play.rectangle")
                }
                .accessibilityLabel("Start slideshow")
                .accessibilityIdentifier("album.slideshow")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if !items.isEmpty {
                Button(isSelecting ? "Done" : "Select") {
                    Haptics.selection()
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
                .accessibilityLabel(isSelecting ? "Finish selecting" : "Select items")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(GallerySort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort album")
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if isSelecting {
            VStack(spacing: 0) {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        action("Share", "square.and.arrow.up") { shareSelection() }
                        action("Favorite", "heart") { favoriteSelection() }
                        action("Cover", "rectangle.dashed") { setCoverFromSelection() }
                        action("Remove", "rectangle.stack.badge.minus") { removeFromAlbum() }
                        action("Trash", "trash") { trashSelection() }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, perform: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            perform()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(minWidth: 52)
        }
        .buttonStyle(.plain)
        .disabled(selection.isEmpty)
        .opacity(selection.isEmpty ? 0.4 : 1)
        .accessibilityLabel(title)
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    // MARK: - Actions

    private func toggleSelection(_ item: VaultMedia) {
        Haptics.selection()
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    private func clampSelection() {
        let valid = Set(items.map(\.id))
        let trimmed = selection.intersection(valid)
        if trimmed != selection { selection = trimmed }
    }

    private func removeFromAlbum() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        // Only the label goes. The encrypted file and the item's other album labels
        // are untouched.
        AlbumEditor.remove(chosen, from: album)
        context.saveReporting { _ in
            alertMessage = "Those items could not be removed from the album."
        }
        Haptics.success()
        selection.removeAll()
        isSelecting = false
    }

    /// Sets the album cover from the first selected item. One cover is meaningful, so
    /// a multi-selection resolves to the earliest item rather than requiring the user
    /// to deselect the rest.
    private func setCoverFromSelection() {
        guard let chosen = selectedItems.first else { return }
        guard AlbumEditor.setCover(chosen, for: album) else {
            alertMessage = "That item is not in this album."
            return
        }
        context.saveReporting { _ in
            alertMessage = "The cover could not be saved."
        }
        Haptics.success()
        selection.removeAll()
        isSelecting = false
    }

    private func startSlideshow() {
        let snapshot = items
        guard !snapshot.isEmpty else {
            alertMessage = "This album has nothing to show yet."
            return
        }
        Haptics.tap()
        slideshowRequest = SlideshowRequest(items: snapshot, startIndex: 0, title: album.name)
    }

    /// Adds vault items to this album from inside the album.
    ///
    /// Shows the whole live library with already-filed items disabled, so the screen
    /// answers "what else could go in here" instead of asking the user to remember.
    private var addPhotosSheet: some View {
        AddToAlbumSheet(album: album, candidates: allMedia) { chosen in
            guard AlbumEditor.add(chosen, to: album) else {
                alertMessage = "Those items are already in this album."
                return
            }
            context.saveReporting { _ in
                alertMessage = "Those items could not be added to the album."
            }
            Haptics.success()
        }
    }

    private func favoriteSelection() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        let target = !(chosen.first?.isFavorite ?? false)
        for item in chosen { item.isFavorite = target }
        context.saveReporting { _ in
            alertMessage = "The favorite change could not be saved."
        }
        Haptics.success()
    }

    private func trashSelection() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        for item in chosen {
            item.isInTrash = true
            item.trashedAt = Date()
            // Drop the label so the album stops counting an item that is leaving. The
            // file itself is untouched until Recently Deleted purges it.
            item.albumIDs.removeAll()
            if item.album?.id == album.id { item.album = nil }
        }
        context.saveReporting { _ in
            alertMessage = "Those items could not be moved to Recently Deleted."
        }
        Haptics.success()
        selection.removeAll()
        isSelecting = false
    }

    private func shareSelection() {
        let chosen = selectedItems
        guard !chosen.isEmpty else { return }
        Task {
            do {
                shareBundle = try await ShareService.shared.prepare(chosen)
            } catch {
                Haptics.error()
                alertMessage = error.localizedDescription + " Nothing was removed from your vault."
            }
        }
    }
}
