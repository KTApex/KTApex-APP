import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let album: VaultAlbum
    @State private var viewerItem: VaultMedia?
    @State private var isSelecting = false
    @State private var selection = Set<String>()

    private var items: [VaultMedia] {
        album.media.filter { !$0.isInTrash }.sorted(by: { $0.createdAt > $1.createdAt })
    }

    var body: some View {
        Group {
            if items.isEmpty {
                MVEmptyState(
                    symbol: "folder",
                    title: "Album is empty",
                    subtitle: "Import photos into the vault, then move them here."
                )
            } else {
                MediaGrid(items: items, selection: $selection, isSelecting: $isSelecting) { item in
                    viewerItem = item
                }
            }
        }
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    Haptics.selection()
                    isSelecting.toggle()
                    if !isSelecting { selection.removeAll() }
                }
            }
            if isSelecting && !selection.isEmpty {
                ToolbarItem(placement: .bottomBar) {
                    Button("Remove from Album") { removeSelected() }
                }
            }
        }
        .fullScreenCover(isPresented: Binding(get: { viewerItem != nil }, set: { if !$0 { viewerItem = nil } })) {
            if let item = viewerItem { MediaViewerView(items: items, selectedID: item.id) }
        }
    }

    private func removeSelected() {
        for m in album.media where selection.contains(m.id) {
            m.album = nil
        }
        try? context.save()
        Haptics.success()
        selection.removeAll()
        isSelecting = false
    }
}
