import SwiftUI
import SwiftData

/// Recently Deleted: a 30-day safety net in front of permanent removal.
///
/// Trashing is deliberately cheap (one tap, reversible) while permanent deletion
/// always asks first, and only this screen ever deletes vault ciphertext.
struct TrashView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<VaultMedia> { $0.isInTrash }, sort: \VaultMedia.createdAt, order: .reverse)
    private var trashed: [VaultMedia]

    /// Both confirmation paths share one dialog: a view can only present one
    /// confirmation dialog reliably, so the pending action decides its wording.
    private enum TrashAction: Identifiable {
        case single(String)
        case all

        var id: String {
            switch self {
            case .single(let id): return id
            case .all: return "all"
            }
        }
    }

    @State private var pending: TrashAction?
    @State private var viewerItem: VaultMedia?
    @State private var alertMessage: String?

    private var items: [VaultMedia] {
        guard !appState.isDecoyMode else { return [] }
        return trashed.sorted { ($0.trashedAt ?? $0.createdAt) > ($1.trashedAt ?? $1.createdAt) }
    }

    var body: some View {
        Group {
            if items.isEmpty {
                MVEmptyState(
                    symbol: "trash",
                    title: "Trash is empty",
                    subtitle: "Deleted items stay here for 30 days, then are removed permanently."
                )
            } else {
                List {
                    Section {
                        ForEach(items) { item in
                            row(item)
                        }
                    } footer: {
                        Text("Items older than 30 days are removed permanently. Nothing here is uploaded anywhere.")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Recently Deleted")
        .toolbar {
            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Empty", role: .destructive) { pending = .all }
                        .accessibilityLabel("Empty trash")
                }
            }
        }
        .confirmationDialog(
            dialogTitle,
            isPresented: dialogBinding,
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button("Delete Permanently", role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(dialogMessage(action))
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewerView(items: items, selectedID: item.id, title: "Recently Deleted")
                .environmentObject(appState)
        }
        .alert("Trash", isPresented: alertBinding) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .onAppear { purgeExpired() }
    }

    private func row(_ item: VaultMedia) -> some View {
        HStack(spacing: 12) {
            MediaThumbnailView(item: item, pixelSize: 160)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))

            Button {
                viewerItem = item
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName.isEmpty ? (item.isVideo ? "Video" : "Photo") : item.fileName)
                        .font(MVFont.headline)
                        .lineLimit(1)
                    Text(subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button("Restore") { restore(item) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Restore \(item.fileName)")
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) { pending = .single(item.id) }
        }
    }

    private func subtitle(for item: VaultMedia) -> String {
        let when = (item.trashedAt ?? item.createdAt).formatted(date: .abbreviated, time: .shortened)
        let size = StorageService.formatted(item.fileSize)
        return "Deleted \(when) · \(size)"
    }

    // MARK: - Bindings

    private var dialogBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })
    }

    private var dialogTitle: String {
        switch pending {
        case .single: return "Delete permanently?"
        case .all: return "Empty trash?"
        case nil: return "Delete permanently?"
        }
    }

    private func dialogMessage(_ action: TrashAction) -> String {
        switch action {
        case .single(let id):
            let name = items.first { $0.id == id }?.fileName ?? "This item"
            return "“\(name)” will be removed from this device and cannot be recovered."
        case .all:
            return "All \(items.count) trashed item\(items.count == 1 ? "" : "s") will be removed from this device and cannot be recovered."
        }
    }

    // MARK: - Actions

    private func perform(_ action: TrashAction) {
        switch action {
        case .single(let id):
            guard let item = items.first(where: { $0.id == id }) else { break }
            permanentlyDelete(item)
        case .all:
            for item in items { permanentlyDelete(item) }
        }
        pending = nil
        Haptics.success()
    }

    private func restore(_ item: VaultMedia) {
        item.isInTrash = false
        item.trashedAt = nil
        context.saveReporting { _ in
            alertMessage = "That item could not be restored."
        }
        Haptics.success()
    }

    private func permanentlyDelete(_ item: VaultMedia) {
        // The ciphertext goes first: if the row were deleted first and the file
        // removal failed, an orphaned vault file would linger with no way to find it.
        VaultStorageService.shared.delete(fileName: item.encryptedFileName)
        context.delete(item)
        context.saveReporting { _ in
            alertMessage = "An item could not be removed. Its encrypted file was kept so nothing is lost."
        }
    }

    private func purgeExpired() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) else { return }
        let expired = items.filter { ($0.trashedAt ?? $0.createdAt) < cutoff }
        guard !expired.isEmpty else { return }
        for item in expired { permanentlyDelete(item) }
    }
}
