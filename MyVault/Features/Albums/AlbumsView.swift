import SwiftUI
import SwiftData

/// Album browser. Pushed from the vault, so it does not create its own
/// `NavigationStack`.
///
/// An album is a *label* on encrypted media, never a container of its own: deleting
/// an album detaches its items and leaves every vault file exactly where it was.
struct AlbumsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var appState: AppState
    @Query(sort: \VaultAlbum.createdAt) private var albums: [VaultAlbum]
    @Query(sort: \VaultMedia.createdAt, order: .reverse) private var liveMedia: [VaultMedia]

    enum AlbumSort: String, CaseIterable, Identifiable {
        case name, newest, itemCount

        var id: String { rawValue }

        var title: String {
            switch self {
            case .name: return "Name"
            case .newest: return "Newest"
            case .itemCount: return "Most Items"
            }
        }
    }

    @State private var searchText = ""
    @State private var sort: AlbumSort = .name
    @State private var showingNew = false
    @State private var newName = ""
    @State private var renaming: VaultAlbum?
    @State private var renameText = ""
    @State private var deleting: VaultAlbum?
    @State private var alertMessage: String?

    private var visibleAlbums: [VaultAlbum] {
        guard !appState.isDecoyMode else { return [] }
        var list = albums
        if !searchText.isBlank {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        switch sort {
        case .name: list = AlbumEditor.sorted(list)
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .itemCount: list.sort { $0.itemCount(in: liveMedia) > $1.itemCount(in: liveMedia) }
        }
        return list
    }

    var body: some View {
        Group {
            if appState.isDecoyMode || albums.isEmpty {
                MVEmptyState(
                    symbol: "rectangle.stack",
                    title: "No albums yet",
                    subtitle: "Group related media without copying it: an album is a label on the encrypted item.",
                    actionTitle: "New Album",
                    action: { newName = ""; showingNew = true }
                )
            } else if visibleAlbums.isEmpty {
                MVEmptyState(
                    symbol: "magnifyingglass",
                    title: "No matching albums",
                    subtitle: "No album name contains “\(searchText)”.",
                    actionTitle: "Clear Search",
                    action: { searchText = "" }
                )
            } else {
                List {
                    ForEach(visibleAlbums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                        } label: {
                            // The library is passed in so a cover can be resolved from
                            // the album's real members (and its chosen cover) rather
                            // than by walking a relationship that may lag behind.
                            AlbumRow(album: album, library: liveMedia)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { deleting = album }
                            Button("Rename") { renameText = album.name; renaming = album }
                                .tint(.accentColor)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Albums")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(AlbumSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort albums")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newName = ""; showingNew = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New album")
            }
        }
        .sheet(isPresented: $showingNew) { newAlbumSheet }
        .alert("Rename Album", isPresented: renameBinding) {
            TextField("Album name", text: $renameText)
            Button("Save") { commitRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: deleteBinding,
            titleVisibility: .visible,
            presenting: deleting
        ) { album in
            Button("Delete Album", role: .destructive) { delete(album) }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { album in
            let count = album.itemCount(in: liveMedia)
            Text("The \(count) item\(count == 1 ? "" : "s") in this album stay in your vault - only the album is removed.")
        }
        .alert("Album not saved", isPresented: alertBinding) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var newAlbumSheet: some View {
        NavigationStack {
            Form {
                TextField("Album name", text: $newName)
                    .accessibilityLabel("Album name")
            }
            .navigationTitle("New Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNew = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(newName.isBlank)
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Bindings

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    // MARK: - Actions

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isBlank else { return }
        context.insert(VaultAlbum(name: name))
        do {
            try context.save()
            Haptics.success()
        } catch {
            context.rollback()
            alertMessage = "The album could not be saved. Nothing else changed."
        }
        newName = ""
        showingNew = false
    }

    private func commitRename() {
        guard let album = renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isBlank else { renaming = nil; return }
        album.name = name
        context.saveReporting { _ in
            alertMessage = "The new name could not be saved."
        }
        Haptics.success()
        renaming = nil
    }

    /// Deletes the album and nothing else.
    ///
    /// Membership is stripped from the items first, so no item keeps a label pointing
    /// at an album that no longer exists. The encrypted files are never touched: this
    /// removes a way of grouping the library, not its contents.
    private func delete(_ album: VaultAlbum) {
        // Every item in the library is inspected, not just `album.media`: with the
        // multi-album model the relationship can lag behind the ID list, and a stale
        // ID would resurrect the album in a filter.
        AlbumEditor.detachAll(in: liveMedia, albumID: album.id)
        for item in album.media { item.album = nil }
        context.delete(album)
        context.saveReporting { _ in
            alertMessage = "The album could not be deleted."
        }
        Haptics.success()
        deleting = nil
    }
}

/// Cover card used by the home screen's horizontal album strip. Shows the album's
/// chosen cover, falling back to its newest live item rather than a generic folder.
struct AlbumCard: View {
    let album: VaultAlbum
    @Query(sort: \VaultMedia.createdAt, order: .reverse) private var allMedia: [VaultMedia]

    private var cover: VaultMedia? { AlbumEditor.cover(for: album, from: allMedia) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let cover {
                    MediaThumbnailView(item: cover, pixelSize: 320)
                } else {
                    ZStack {
                        Rectangle().fill(Color.accentColor.opacity(0.15))
                        Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.tint)
                    }
                }
            }
            .frame(height: 110)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: MVRadius.m, style: .continuous))
            Text(album.name).font(MVFont.headline).lineLimit(1)
            Text("\(album.itemCount(in: allMedia)) \(album.itemCount(in: allMedia) == 1 ? "item" : "items")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name), \(album.itemCount(in: allMedia)) items")
    }
}

struct AlbumRow: View {
    let album: VaultAlbum
    /// Live library, passed in by the list so each row does not run its own query.
    var library: [VaultMedia] = []

    private var cover: VaultMedia? {
        library.isEmpty
            ? album.media.first { !$0.isInTrash }
            : AlbumEditor.cover(for: album, from: library)
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover {
                    MediaThumbnailView(item: cover, pixelSize: 160)
                } else {
                    ZStack {
                        Rectangle().fill(Color.accentColor.opacity(0.15))
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(MVFont.headline).lineLimit(1)
                Text("\(count) \(count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name), \(count) items")
    }

    /// Counted against the live library when available, so an item filed into this
    /// album second still counts.
    private var count: Int { album.itemCount(in: library) }
}
