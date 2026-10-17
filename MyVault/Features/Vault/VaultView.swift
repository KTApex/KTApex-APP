import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// The vault gallery.
///
/// Layout is a `LazyVGrid` of 2–5 columns with day/month/year grouping, and every
/// expensive step (decode, encrypt, decrypt for sharing) is deliberately off the
/// main actor. The destructive Photos operation — removing originals — is offered
/// only after `ImportCoordinator` has verified the encrypted copy, and only after
/// an explicit confirmation.
struct VaultView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var appState: AppState
    @Query(sort: \VaultAlbum.createdAt) private var albums: [VaultAlbum]
    @Query(sort: \VaultMedia.createdAt, order: .reverse) private var media: [VaultMedia]

    @StateObject private var importer = ImportCoordinator()

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var searchText = ""
    @State private var filter: MediaFilter = .all
    @State private var sortOrder: GallerySort = .newest
    @State private var grouping: GalleryGrouping = .day
    @AppStorage("mv.galleryColumns") private var columnCount = 3
    @State private var selectedAlbumID: String?

    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewerItem: VaultMedia?

    @State private var shareBundle: ShareService.Prepared?
    @State private var alertItem: VaultAlert?

    @State private var showingNewAlbum = false
    @State private var newAlbumName = ""
    @State private var showingTrash = false
    @State private var showingAlbums = false

    /// One alert channel for the whole screen. Presenting two independent alerts
    /// from the same view is unreliable, so importer notices and local failures are
    /// funnelled here.
    struct VaultAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var actionTitle: String? = nil
        var action: (() -> Void)? = nil
        var isError: Bool = false
    }

    // MARK: - Derived data

    private var selectedAlbum: VaultAlbum? {
        guard let selectedAlbumID else { return nil }
        return albums.first { $0.id == selectedAlbumID }
    }

    private var visibleMedia: [VaultMedia] {
        GalleryComposer.sort(
            GalleryComposer.filter(media, search: searchText, filter: filter, album: selectedAlbum),
            by: sortOrder
        )
    }

    private var sections: [GallerySection] {
        GalleryComposer.sections(visibleMedia, grouping: grouping)
    }

    private var selectedMedia: [VaultMedia] {
        media.filter { selection.contains($0.id) }
    }

    private var isFiltered: Bool {
        filter != .all || selectedAlbum != nil || !searchText.isBlank
    }

    // MARK: - Body

    /// The body is deliberately split into layers. One long chain of modifiers,
    /// sheets, dialogs and inline closures inside a single expression makes the
    /// Swift type checker give up ("unable to type-check this expression in
    /// reasonable time"), so each layer stays small enough to check on its own and
    /// the closure bodies live in ordinary methods.
    var body: some View {
        chrome
            .sheet(isPresented: $showingNewAlbum) { newAlbumSheet }
            // The viewer is a *full-screen* destination, not a card. A `.sheet`
            // leaves the gallery visible around a partial-height panel, which is
            // what made the grid appear to bleed through the viewer and made the
            // viewer feel like an overlay. `fullScreenCover` gives it the whole
            // screen, its own presentation layer above the tab bar, and correct
            // safe-area ownership.
            .fullScreenCover(item: $viewerItem) { item in
                MediaViewerView(items: visibleMedia, selectedID: item.id)
            }
            .confirmationDialog(
                "Remove originals from Photos?",
                isPresented: removalBinding,
                titleVisibility: .visible,
                presenting: importer.removalRequest
            ) { request in
                removalDialogButtons(request)
            } message: { request in
                Text(removalMessage(request))
            }
            .alert(
                alertItem?.title ?? "",
                isPresented: alertBinding,
                presenting: alertItem
            ) { item in
                alertButtons(item)
            } message: { item in
                Text(item.message)
            }
            .vaultShareSheet(prepared: $shareBundle) { skipped in
                reportSkippedShares(skipped)
            }
            .onChange(of: pickerItems) { _, items in handlePickedItems(items) }
            .onChange(of: importer.notice) { _, notice in showNotice(notice) }
            .onChange(of: visibleMedia.count) { _, _ in clampSelection() }
    }

    /// Navigation, search and the toolbar.
    ///
    /// Order matters here. `.searchable` installs the search field into the
    /// navigation bar and manages the top safe area itself, so it is attached to
    /// the `NavigationStack` *before* any `safeAreaInset`. The top inset only
    /// carries transient content (import progress, active-filter chips) and
    /// collapses to zero height when there is nothing to show, so it can never
    /// push the search field or the grid around.
    private var chrome: some View {
        navigationStack
            .navigationTitle("Vault")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(isPresented: $showingTrash) { TrashView() }
            .navigationDestination(isPresented: $showingAlbums) { AlbumsView() }
            .searchable(text: $searchText, prompt: "Search photos, videos, albums, dates")
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top, spacing: 0) { topBanner }
            // The selection bar is the *only* thing this screen docks above the tab
            // bar, and only while selecting. It renders nothing otherwise, so it
            // contributes no height and cannot create a gap.
            .safeAreaInset(edge: .bottom, spacing: 0) { selectionBar }
            // Stable handle for UI tests: present regardless of whether the vault
            // has content, and independent of how a TabView reports its navigation bar.
            .accessibilityIdentifier("vault.screen")
    }

    private var navigationStack: some View {
        NavigationStack {
            grid
                .photosPicker(
                    isPresented: $showingPicker,
                    selection: $pickerItems,
                    maxSelectionCount: 50,
                    matching: .any(of: [.images, .videos])
                )
        }
    }

    @ViewBuilder
    private var grid: some View {
        if visibleMedia.isEmpty {
            // The empty state fills the viewport: a short centred block would leave
            // the same dead gap the gallery itself used to leave.
            ScrollView(.vertical) {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.top, 64)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MVColor.galleryBackground)
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

    // MARK: - Presentation closures

    @ViewBuilder
    private func alertButtons(_ item: VaultAlert) -> some View {
        if let actionTitle = item.actionTitle {
            Button(actionTitle) {
                item.action?()
                alertItem = nil
                importer.dismissNotice()
            }
        }
        Button("OK", role: .cancel) {
            alertItem = nil
            importer.dismissNotice()
        }
    }

    @ViewBuilder
    private func removalDialogButtons(_ request: ImportCoordinator.RemovalRequest) -> some View {
        Button(removalButtonTitle(request), role: .destructive) { importer.confirmRemoval() }
        Button("Keep in Photos", role: .cancel) { importer.keepOriginals() }
    }

    private func handlePickedItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        importer.start(items, context: context, album: selectedAlbum)
        pickerItems = []
    }

    private func showNotice(_ notice: ImportCoordinator.Notice?) {
        guard let notice else { return }
        // The importer keeps its notice until the user answers, because the
        // permission action reads it back when it runs.
        alertItem = VaultAlert(
            title: notice.title,
            message: notice.message,
            actionTitle: notice.actionTitle,
            action: notice.action == nil ? nil : { importer.performNoticeAction() },
            isError: notice.isError
        )
    }

    private func reportSkippedShares(_ skipped: [String]) {
        var message = "These items could not be decrypted, so they were left out: "
            + skipped.prefix(5).joined(separator: ", ")
        if skipped.count > 5 { message += " and \(skipped.count - 5) more" }
        alertItem = VaultAlert(
            title: "Some items were not shared",
            message: message + ".",
            isError: true
        )
    }

    // MARK: - Sections of the screen

    @ViewBuilder
    private var emptyState: some View {
        if isFiltered {
            MVEmptyState(
                symbol: "magnifyingglass",
                title: "No matches",
                subtitle: filter == .all
                    ? "Nothing in the vault matches this search or album."
                    : filter.emptyMessage,
                actionTitle: "Clear Filters",
                action: clearFilters
            )
        } else {
            MVEmptyState(
                symbol: "photo.stack",
                title: "No private memories yet",
                subtitle: "Photos and videos are encrypted on this device before they are stored.",
                actionTitle: "Import Photos",
                action: beginImport
            )
        }
    }

    /// Transient content above the grid. Rendered as *nothing* when idle so the
    /// inset contributes no height and cannot shift the search field or grid.
    @ViewBuilder
    private var topBanner: some View {
        if importer.isWorking || (isFiltered && !visibleMedia.isEmpty) {
            VStack(spacing: 8) {
                if importer.isWorking {
                    MVProgressCard(
                        title: importer.workingLabel,
                        detail: "Items already verified stay in the vault.",
                        progress: importer.progress,
                        onCancel: importer.canCancel ? { importer.cancel() } : nil
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
                if isFiltered && !visibleMedia.isEmpty {
                    activeFilterBar
                }
            }
            .background(.bar)
        }
    }

    private var activeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filter != .all {
                    MVFilterChip(title: filter.title, symbol: filter.symbol) { filter = .all }
                }
                if let album = selectedAlbum {
                    MVFilterChip(title: album.name, symbol: "rectangle.stack") { selectedAlbumID = nil }
                }
                if !searchText.isBlank {
                    MVFilterChip(title: searchText, symbol: "magnifyingglass") { searchText = "" }
                }
                MVFilterChip(title: "Clear all", symbol: "xmark.circle") { clearFilters() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// Selection actions, docked above the tab bar. Absent (zero height) unless a
    /// selection is active, so the grid's last row is never reserved against.
    @ViewBuilder
    private var selectionBar: some View {
        if isSelecting {
            VStack(spacing: 0) {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        selectionAction("Share", "square.and.arrow.up") { shareSelection() }
                        selectionAction("Favorite", "heart") { favoriteSelection() }
                        albumMenu
                        if selectedAlbum != nil {
                            selectionAction("Remove", "rectangle.stack.badge.minus") { removeSelectionFromAlbum() }
                        }
                        selectionAction("Trash", "trash") { trashSelection() }
                        selectionAction(
                            selection.count == visibleMedia.count ? "Deselect" : "Select All",
                            "checkmark.circle"
                        ) { toggleSelectAll() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .background(.bar)
            .transition(.move(edge: .bottom))
        }
    }

    private func selectionAction(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
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

    private var albumMenu: some View {
        Menu {
            if albums.isEmpty {
                Text("No albums yet")
            } else {
                ForEach(albums) { album in
                    Button(album.name) { moveSelection(to: album) }
                }
            }
            Divider()
            Button {
                newAlbumName = ""
                showingNewAlbum = true
            } label: {
                Label("New Album…", systemImage: "folder.badge.plus")
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "rectangle.stack.badge.plus").font(.title3)
                Text("Album").font(.caption2)
            }
            .frame(minWidth: 52)
        }
        .disabled(selection.isEmpty)
        .opacity(selection.isEmpty ? 0.4 : 1)
        .accessibilityLabel("Add to album")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if !visibleMedia.isEmpty {
                Button(isSelecting ? "Done" : "Select") { toggleSelecting() }
                    .accessibilityLabel(isSelecting ? "Finish selecting" : "Select items")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button(action: beginImport) {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Import photos or videos")
            Menu { moreMenu } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More options")
        }
    }

    @ViewBuilder
    private var moreMenu: some View {
        Section("Layout") {
            Picker("Columns", selection: $columnCount) {
                Text("2 Columns").tag(2)
                Text("3 Columns").tag(3)
                Text("4 Columns").tag(4)
                Text("5 Columns").tag(5)
            }
            Picker("Grouping", selection: $grouping) {
                ForEach(GalleryGrouping.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        }
        Section("Show") {
            Picker("Filter", selection: $filter) {
                ForEach(MediaFilter.allCases) { option in
                    Label(option.title, systemImage: option.symbol).tag(option)
                }
            }
            Picker("Sort", selection: $sortOrder) {
                ForEach(GallerySort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            if !albums.isEmpty {
                Picker("Album", selection: albumBinding) {
                    Text("All Albums").tag(String?.none)
                    ForEach(albums) { album in
                        Text(album.name).tag(String?.some(album.id))
                    }
                }
            }
        }
        Section("Albums") {
            Button { showingAlbums = true } label: { Label("Browse Albums", systemImage: "rectangle.stack") }
            Button { newAlbumName = ""; showingNewAlbum = true } label: {
                Label("New Album", systemImage: "folder.badge.plus")
            }
        }
        Section {
            Button { showingTrash = true } label: { Label("Recently Deleted", systemImage: "trash") }
            Button {
                Haptics.tap()
                appState.lock()
            } label: {
                Label("Lock Now", systemImage: "lock.fill")
            }
        }
    }

    private var newAlbumSheet: some View {
        NavigationStack {
            Form {
                TextField("Album name", text: $newAlbumName)
                    .accessibilityLabel("Album name")
                Text("Adding media to an album never copies it: albums are labels on the encrypted items.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNewAlbum = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { createAlbum() }.disabled(newAlbumName.isBlank)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Bindings

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertItem != nil }, set: { if !$0 { alertItem = nil } })
    }

    private var albumBinding: Binding<String?> {
        Binding(get: { selectedAlbumID }, set: { selectedAlbumID = $0 })
    }

    /// Dismissing the dialog without choosing anything means "keep the originals".
    /// `confirmRemoval` and `keepOriginals` both clear `removalRequest` first, so a
    /// trailing dismiss cannot overwrite the user's actual choice.
    private var removalBinding: Binding<Bool> {
        Binding(
            get: { importer.removalRequest != nil },
            set: { presented in
                guard !presented, importer.removalRequest != nil else { return }
                importer.keepOriginals()
            }
        )
    }

    // MARK: - Import

    private func beginImport() {
        Haptics.tap()
        Task {
            await importer.prepareForImport()
            showingPicker = true
        }
    }

    private func removalButtonTitle(_ request: ImportCoordinator.RemovalRequest) -> String {
        "Remove \(request.count) Original\(request.count == 1 ? "" : "s")"
    }

    private func removalMessage(_ request: ImportCoordinator.RemovalRequest) -> String {
        var message = "\(request.count) \(request.count == 1 ? "item was" : "items were") encrypted into your vault and verified. Removing the originals from Photos moves them to Recently Deleted in Photos, where they stay for 30 days."
        if request.limitedAccess {
            message += "\n\nMyVault only has access to the items you allowed in Photos, so any it cannot see will stay in your library."
        }
        return message
    }

    // MARK: - Selection

    private func toggleSelecting() {
        Haptics.selection()
        isSelecting.toggle()
        if !isSelecting { selection.removeAll() }
    }

    private func toggleSelection(_ item: VaultMedia) {
        Haptics.selection()
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    private func toggleSelectAll() {
        Haptics.selection()
        if selection.count == visibleMedia.count {
            selection.removeAll()
        } else {
            selection = Set(visibleMedia.map(\.id))
        }
    }

    private func clearSelection() {
        selection.removeAll()
        isSelecting = false
    }

    private func clampSelection() {
        let valid = Set(visibleMedia.map(\.id))
        let trimmed = selection.intersection(valid)
        if trimmed != selection { selection = trimmed }
    }

    private func clearFilters() {
        Haptics.tap()
        filter = .all
        selectedAlbumID = nil
        searchText = ""
    }

    // MARK: - Album actions

    private func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespaces)
        guard !name.isBlank else { return }
        let album = VaultAlbum(name: name)
        context.insert(album)
        do {
            try context.save()
            Haptics.success()
            selectedAlbumID = album.id
        } catch {
            context.rollback()
            alertItem = VaultAlert(title: "Album not created", message: "The album could not be saved. Nothing else was changed.", isError: true)
        }
        newAlbumName = ""
        showingNewAlbum = false
    }

    private func moveSelection(to album: VaultAlbum) {
        let items = selectedMedia
        guard !items.isEmpty else { return }
        for item in items { item.album = album }
        context.saveReporting { message in
            alertItem = VaultAlert(title: "Album not updated", message: message, isError: true)
        }
        Haptics.success()
        clearSelection()
    }

    private func removeSelectionFromAlbum() {
        let items = selectedMedia
        guard !items.isEmpty else { return }
        for item in items { item.album = nil }
        context.saveReporting { message in
            alertItem = VaultAlert(title: "Album not updated", message: message, isError: true)
        }
        Haptics.success()
        clearSelection()
    }

    // MARK: - Media actions

    private func favoriteSelection() {
        let items = selectedMedia
        guard !items.isEmpty else { return }
        // Toggle against the first item so a mixed selection becomes uniform
        // instead of flipping item by item.
        let target = !(items.first?.isFavorite ?? false)
        for item in items { item.isFavorite = target }
        context.saveReporting { message in
            alertItem = VaultAlert(title: "Favorites not updated", message: message, isError: true)
        }
        Haptics.success()
    }

    private func trashSelection() {
        let items = selectedMedia
        guard !items.isEmpty else { return }
        for item in items {
            item.isInTrash = true
            item.trashedAt = Date()
        }
        context.saveReporting { message in
            alertItem = VaultAlert(title: "Items not deleted", message: message, isError: true)
        }
        Haptics.success()
        clearSelection()
    }

    private func shareSelection() {
        let items = selectedMedia
        guard !items.isEmpty else { return }
        Task {
            do {
                shareBundle = try await ShareService.shared.prepare(items)
            } catch {
                Haptics.error()
                alertItem = VaultAlert(
                    title: "Sharing failed",
                    message: error.localizedDescription + " Nothing was removed from your vault.",
                    isError: true
                )
            }
        }
    }
}

/// Chip that shows an active filter and clears it when tapped.
struct MVFilterChip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption2)
                Text(title).font(.caption).lineLimit(1)
                Image(systemName: "xmark").font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear filter \(title)")
    }
}

extension ModelContext {
    /// Saves and reports the failure instead of discarding it, so a rejected write
    /// cannot look like a successful action.
    func saveReporting(_ onFailure: (String) -> Void) {
        do {
            try save()
        } catch {
            rollback()
            onFailure("That change could not be saved, so nothing was modified. Please try again.")
        }
    }
}
