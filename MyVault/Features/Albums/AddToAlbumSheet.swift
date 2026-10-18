import SwiftUI

/// Picks vault items to file into an album.
///
/// Shows the live library rather than only un-filed items: seeing the whole vault with
/// already-filed items disabled answers "what does this album have, and what else
/// could it have" in one screen. Every item stays in the vault; the sheet only
/// produces IDs and lets the caller write membership.
struct AddToAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss

    let album: VaultAlbum
    let candidates: [VaultMedia]
    let onAdd: ([VaultMedia]) -> Void

    @State private var selected = Set<String>()
    @State private var searchText = ""

    private var memberIDs: Set<String> {
        AlbumEditor.memberIDs(in: album, from: candidates)
    }

    private var selectable: [VaultMedia] {
        candidates
            .filter { !$0.isInTrash }
            .sorted { $0.createdAt > $1.createdAt }
            .filter { item in
                searchText.isBlank || GalleryComposer.matches(item, search: searchText)
            }
    }

    private var chosen: [VaultMedia] {
        selectable.filter { selected.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if selectable.isEmpty {
                    MVEmptyState(
                        symbol: "photo.on.rectangle.angled",
                        title: searchText.isBlank ? "Nothing to add" : "No matches",
                        subtitle: searchText.isBlank
                            ? "Import photos or videos into the vault first."
                            : "Nothing in the vault matches this search."
                    )
                } else {
                    List(selectable) { item in
                        row(for: item)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Add to \(album.name)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search vault")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add\(selected.isEmpty ? "" : " (\(selected.count))")") {
                        let items = chosen
                        dismiss()
                        onAdd(items)
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .accessibilityIdentifier("album.addSheet")
    }

    private func row(for item: VaultMedia) -> some View {
        let isMember = memberIDs.contains(item.id)
        let isSelected = selected.contains(item.id)
        return Button {
            guard !isMember else { return }
            Haptics.selection()
            if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            HStack(spacing: 12) {
                MediaThumbnailView(item: item, pixelSize: 160)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName.isEmpty ? (item.isVideo ? "Video" : "Photo") : item.fileName)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if isMember {
                        Text("Already in this album")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 0)

                if isMember {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isMember)
        .accessibilityLabel(accessibilityLabel(for: item, isMember: isMember))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func accessibilityLabel(for item: VaultMedia, isMember: Bool) -> String {
        let name = item.fileName.isEmpty ? (item.isVideo ? "Video" : "Photo") : item.fileName
        if isMember { return "\(name), already in this album" }
        return selected.contains(item.id) ? "\(name), selected" : name
    }
}
