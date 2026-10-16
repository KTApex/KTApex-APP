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
    let album: VaultAlbum

    @State private var sortOrder: GallerySort = .newest
    @AppStorage("mv.galleryColumns") private var columnCount = 3
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewerItem: VaultMedia?
    @State private var shareBundle: ShareService.Prepared?
    @State private var alertMessage: String?

    private var items: [VaultMedia] {
        GalleryComposer.sort(
            GalleryComposer.filter(album.media, filter: .all, album: album),
            by: sortOrder
        )
    }

    private var sections: [GallerySection] {
        GalleryComposer.sections(items, grouping: .day)
    }

    private var selectedItems: [VaultMedia] {
        items.filter { selection.contains($0.id) }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                MVEmptyState(
                    symbol: "folder",
                    title: "Album is empty",
                    subtitle: "Open a photo or video in the vault and use Add to Album, or select items there and move them here."
                )
            } else {
                GalleryGrid(
                    sections: sections,
                    columnCount: columnCount,
                    isSelecting: isSelecting,
                    selection: $selection,
                    onOpen: { viewerItem = $0 },
                    onToggleSelection: { toggleSelection($0) }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar { toolbarContent }
        .sheet(isPresented: viewerBinding) {
            MediaViewerView(items: items, selectedID: viewerItem?.id)
        }
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
            if !items.isEmpty {
                Button(isSelecting ? "Done" : "Select") {
                    Haptics.selection()
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
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
                HStack(spacing: 22) {
                    action("Share", "square.and.arrow.up") { shareSelection() }
                    action("Favorite", "heart") { favoriteSelection() }
                    action("Remove", "rectangle.stack.badge.minus") { removeFromAlbum() }
                    action("Trash", "trash") { trashSelection() }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
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

    private var viewerBinding: Binding<Bool> {
        Binding(get: { viewerItem != nil }, set: { if !$0 { viewerItem = nil } })
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
        for item in chosen { item.album = nil }
        context.saveReporting { _ in
            alertMessage = "Those items could not be removed from the album."
        }
        Haptics.success()
        selection.removeAll()
        isSelecting = false
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
