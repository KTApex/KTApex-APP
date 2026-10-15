import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct VaultView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VaultAlbum.createdAt) private var albums: [VaultAlbum]
    @Query(sort: \VaultMedia.createdAt, order: .reverse) private var media: [VaultMedia]
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importProgress: Double = 0
    @State private var importError: String?
    @State private var searchText = ""
    @State private var filter: MediaFilter = .all
    @State private var selectedAlbum: VaultAlbum?
    @State private var showingNewAlbum = false
    @State private var newAlbumName = ""
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewerItem: VaultMedia?
    @State private var sortOrder: SortOrder = .newest
    @State private var showPicker = false
    @State private var importedOriginals: [String] = []
    @State private var showingRemoveOriginals = false
    @State private var exportError: String?

    enum MediaFilter: String, CaseIterable { case all, photos, videos, favorites }
    enum SortOrder: String, CaseIterable { case newest, oldest, largest, smallest }

    private var visibleMedia: [VaultMedia] {
        var list = media.filter { !$0.isInTrash }
        if let album = selectedAlbum { list = list.filter { $0.album?.id == album.id } }
        switch filter {
        case .photos: list = list.filter { !$0.isVideo }
        case .videos: list = list.filter(\.isVideo)
        case .favorites: list = list.filter(\.isFavorite)
        case .all: break
        }
        if !searchText.isBlank {
            list = list.filter { $0.fileName.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOrder {
        case .newest: list.sort { $0.createdAt > $1.createdAt }
        case .oldest: list.sort { $0.createdAt < $1.createdAt }
        case .largest: list.sort { $0.fileSize > $1.fileSize }
        case .smallest: list.sort { $0.fileSize < $1.fileSize }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filter) {
                    ForEach(MediaFilter.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if isImporting {
                    VStack(spacing: 8) {
                        ProgressView(value: importProgress) { Text("Importing & encrypting…") }
                    }
                    .padding()
                }

                if visibleMedia.isEmpty && !isImporting {
                    MVEmptyState(
                        symbol: "photo.stack",
                        title: "No private memories yet",
                        subtitle: "Add your first photo to start your encrypted vault.",
                        actionTitle: "Import Photos",
                        action: { showPicker = true }
                    )
                } else {
                    MediaGrid(items: visibleMedia, selection: $selection, isSelecting: $isSelecting) { item in
                        viewerItem = item
                    }
                }
            }
            .navigationTitle("Vault")
            .searchable(text: $searchText, prompt: "Search vault")
            .photosPicker(isPresented: $showPicker, selection: $pickerItems, matching: .any(of: [.images, .videos]))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isSelecting ? "Done" : "Select") {
                        Haptics.selection()
                        isSelecting.toggle()
                        if !isSelecting { selection.removeAll() }
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import photos")
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                        }
                        Button("New Album") { showingNewAlbum = true }
                        if !albums.isEmpty {
                            Menu("Filter by Album") {
                                Button("All Albums") { selectedAlbum = nil }
                                ForEach(albums) { a in Button(a.name) { selectedAlbum = a } }
                            }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
                if isSelecting && !selection.isEmpty {
                    ToolbarItem(placement: .bottomBar) {
                        HStack {
                            Button("Export") { exportSelected() }
                            if !albums.isEmpty {
                                Menu("Move to") {
                                    ForEach(albums) { a in
                                        Button(a.name) { moveSelected(to: a) }
                                    }
                                }
                            }
                            Spacer()
                            Button("Trash", role: .destructive) { trashSelected() }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingNewAlbum) {
                NavigationStack {
                    Form {
                        TextField("Album name", text: $newAlbumName)
                            .accessibilityLabel("Album name")
                    }
                    .navigationTitle("New Album")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNewAlbum = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create") { createAlbum() }.disabled(newAlbumName.isBlank)
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .fullScreenCover(isPresented: viewerBinding) {
                if let item = viewerItem {
                    MediaViewerView(items: visibleMedia, selectedID: item.id)
                }
            }
            .onChange(of: pickerItems) { _, items in importItems(items) }
            .alert("Import failed", isPresented: importErrorBinding) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .alert("Export failed", isPresented: exportErrorBinding) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
            .confirmationDialog(
                "Remove originals from Photos?",
                isPresented: $showingRemoveOriginals,
                titleVisibility: .visible
            ) {
                Button("Remove Originals", role: .destructive) { removeOriginalAssets() }
                Button("Keep Originals", role: .cancel) {}
            } message: {
                Text("The original items will be removed from your Photos library after confirmation.")
            }
        }
    }

    private var viewerBinding: Binding<Bool> {
        Binding(get: { viewerItem != nil }, set: { if !$0 { viewerItem = nil } })
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
    }

    private func createAlbum() {
        let album = VaultAlbum(name: newAlbumName.trimmingCharacters(in: .whitespaces))
        context.insert(album)
        try? context.save()
        Haptics.success()
        newAlbumName = ""
        showingNewAlbum = false
    }

    private func trashSelected() {
        for m in media where selection.contains(m.id) {
            m.isInTrash = true
            m.trashedAt = Date()
        }
        try? context.save()
        Haptics.success()
        selection.removeAll()
        isSelecting = false
    }

    private func moveSelected(to album: VaultAlbum) {
        for m in media where selection.contains(m.id) {
            m.album = album
        }
        try? context.save()
        Haptics.success()
        selection.removeAll()
        isSelecting = false
    }

    private func exportSelected() {
        let selected = media.filter { selection.contains($0.id) }
        Task {
            for m in selected {
                do {
                    let data = try VaultStorageService.shared.loadDecrypted(fileName: m.encryptedFileName)
                    try await PhotoLibraryService.shared.export(data: data, isVideo: m.isVideo)
                } catch {
                    await MainActor.run {
                        exportError = "One item could not be exported. The rest were kept safe."
                    }
                }
            }
            await MainActor.run {
                Haptics.success()
                selection.removeAll()
                isSelecting = false
            }
        }
    }

    private func removeOriginalAssets() {
        let ids = importedOriginals
        importedOriginals = []
        Task {
            do {
                try await PhotoLibraryService.shared.deleteAssets(localIdentifiers: ids)
                await MainActor.run { Haptics.success() }
            } catch {
                await MainActor.run {
                    exportError = "Originals could not be removed. They remain in your Photos library."
                }
            }
        }
    }

    private func importItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isImporting = true
        importProgress = 0
        Task {
            var done = 0
            var originals: [String] = []
            for item in items {
                do {
                    if let assetID = item.itemIdentifier { originals.append(assetID) }
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    // PhotosPicker transfers raw bytes; if they decode as an image it is a photo, otherwise video.
                    let isVideo = UIImage(data: data) == nil
                    let fileName = "Import \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                    let stored = try VaultStorageService.shared.storeEncrypted(data: data)
                    let hash = EncryptionService.sha256(data)
                    await MainActor.run {
                        let m = VaultMedia(
                            fileName: fileName,
                            encryptedFileName: stored,
                            mediaType: isVideo ? "video" : "photo",
                            fileSize: data.count,
                            contentHash: hash
                        )
                        m.album = selectedAlbum
                        context.insert(m)
                    }
                } catch {
                    await MainActor.run { importError = "One item could not be imported. The rest were kept safe." }
                }
                done += 1
                await MainActor.run { importProgress = Double(done) / Double(items.count) }
            }
            await MainActor.run {
                try? context.save()
                isImporting = false
                pickerItems = []
                Haptics.success()
                if !originals.isEmpty {
                    importedOriginals = originals
                    showingRemoveOriginals = true
                }
            }
        }
    }
}

struct MediaGrid: View {
    let items: [VaultMedia]
    @Binding var selection: Set<String>
    @Binding var isSelecting: Bool
    let onTap: (VaultMedia) -> Void

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    MediaThumb(item: item, selected: selection.contains(item.id))
                        .onTapGesture {
                            if isSelecting {
                                Haptics.selection()
                                if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
                            } else {
                                onTap(item)
                            }
                        }
                        .accessibilityLabel(item.fileName)
                }
            }
        }
    }
}

struct MediaThumb: View {
    let item: VaultMedia
    let selected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle().fill(Color.secondary.opacity(0.15)).aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                    else if item.isVideo { Image(systemName: "video.fill").font(.title).foregroundStyle(.secondary) }
                    else { Image(systemName: "photo").font(.title).foregroundStyle(.secondary) }
                }
                .clipped()
            if item.isFavorite {
                Image(systemName: "heart.fill").foregroundStyle(.red).padding(6)
            }
            if selected {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { image = ThumbnailCache.shared.thumbnail(for: item) }
    }
}
