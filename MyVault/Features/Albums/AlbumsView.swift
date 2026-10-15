import SwiftUI
import SwiftData

struct AlbumCard: View {
    let album: VaultAlbum
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: MVRadius.m)
                .fill(Color.accentColor.opacity(0.15))
                .frame(height: 110)
                .overlay { Image(systemName: "folder.fill").font(.largeTitle).foregroundStyle(.tint) }
            Text(album.name).font(MVFont.headline).lineLimit(1)
            Text("\(album.itemCount) items").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.name), \(album.itemCount) items")
    }
}

struct AlbumsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \VaultAlbum.createdAt) private var albums: [VaultAlbum]
    @State private var path = NavigationPath()
    @State private var showingNew = false
    @State private var name = ""
    @State private var renaming: VaultAlbum?
    @State private var renameText = ""

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(albums) { album in
                    NavigationLink(value: album.id) {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.tint)
                            VStack(alignment: .leading) {
                                Text(album.name).font(MVFont.headline)
                                Text("\(album.itemCount) items").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { delete(album) }
                        Button("Rename") { renaming = album; renameText = album.name }
                    }
                }
            }
            .navigationDestination(for: String.self) { id in
                if let album = albums.first(where: { $0.id == id }) {
                    AlbumDetailView(album: album)
                }
            }
            .navigationTitle("Albums")
        .toolbar {
            Button { showingNew = true } label: { Image(systemName: "plus") }
                .accessibilityLabel("New album")
        }
        .sheet(isPresented: $showingNew) {
            NavigationStack {
                Form { TextField("Album name", text: $name) }
                    .navigationTitle("New Album")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingNew = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Create") {
                                context.insert(VaultAlbum(name: name)); try? context.save()
                                name = ""; showingNew = false; Haptics.success()
                            }.disabled(name.isBlank)
                        }
                    }
            }
            .presentationDetents([.medium])
        }
        .alert("Rename Album", isPresented: renameBinding) {
            TextField("Name", text: $renameText)
            Button("Save") {
                renaming?.name = renameText; try? context.save(); renaming = nil; Haptics.success()
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func delete(_ album: VaultAlbum) {
        for m in album.media { m.album = nil }
        context.delete(album)
        try? context.save()
        Haptics.success()
    }
}
