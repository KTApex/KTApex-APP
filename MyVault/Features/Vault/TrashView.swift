import SwiftUI
import SwiftData

struct TrashView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<VaultMedia> { $0.isInTrash }, sort: \VaultMedia.createdAt, order: .reverse)
    private var trashed: [VaultMedia]
    @State private var confirmingDeleteAll = false

    var body: some View {
        Group {
            if trashed.isEmpty {
                MVEmptyState(symbol: "trash", title: "Trash is empty", subtitle: "Deleted items stay here for 30 days before permanent removal.")
            } else {
                List {
                    ForEach(trashed) { item in
                        HStack {
                            Image(systemName: item.isVideo ? "video.fill" : "photo.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(item.fileName).lineLimit(1)
                                if let t = item.trashedAt {
                                    Text("Deleted \(t.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Restore") { restore(item) }.buttonStyle(.bordered)
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { permanentlyDelete(item) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            if !trashed.isEmpty {
                Button("Delete All", role: .destructive) { confirmingDeleteAll = true }
            }
        }
        .confirmationDialog("Permanently delete everything in trash?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { purgeExpired() }
    }

    private func restore(_ item: VaultMedia) {
        item.isInTrash = false
        item.trashedAt = nil
        try? context.save()
        Haptics.success()
    }

    private func permanentlyDelete(_ item: VaultMedia) {
        VaultStorageService.shared.delete(fileName: item.encryptedFileName)
        context.delete(item)
        try? context.save()
        Haptics.success()
    }

    private func deleteAll() {
        for item in trashed { permanentlyDelete(item) }
    }

    private func purgeExpired() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        for item in trashed where (item.trashedAt ?? Date()) < cutoff {
            permanentlyDelete(item)
        }
    }
}
