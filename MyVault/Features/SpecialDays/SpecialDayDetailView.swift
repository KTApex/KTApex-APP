import SwiftUI
import SwiftData

struct SpecialDayDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var appState: AppState
    @Query(sort: \VaultMedia.createdAt, order: .reverse) private var media: [VaultMedia]
    @Query(sort: \VaultAlbum.createdAt) private var albums: [VaultAlbum]
    @State private var showingEditor = false
    @State private var viewerItem: VaultMedia?
    let event: SpecialDay

    private var occ: CountdownEngine.Occurrence { CountdownEngine.nextOccurrence(of: event) }
    private var cover: VaultMedia? { event.coverMedia(in: media) }
    private var linkedAlbum: VaultAlbum? { event.linkedAlbum(in: albums) }
    private var albumItems: [VaultMedia] {
        guard let linkedAlbum else { return [] }
        return AlbumEditor.items(in: linkedAlbum, from: media)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let cover {
                    Button {
                        viewerItem = cover
                    } label: {
                        MediaThumbnailView(item: cover, pixelSize: 640)
                            .frame(height: 220)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: MVRadius.l, style: .continuous))
                            .padding(.horizontal)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: event.type.symbol)
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                }
                Text(event.title).font(MVFont.greeting)
                Text(CountdownEngine.headline(for: event))
                    .font(MVFont.countdown)
                Text("Next: \(occ.nextDate.formatted(date: .long, time: .omitted))")
                    .foregroundStyle(.secondary)
                if occ.yearsCompleted > 0 {
                    Text("\(occ.yearsCompleted) \(occ.yearsCompleted == 1 ? "year" : "years") together")
                        .font(MVFont.headline)
                }
                if !event.notes.isEmpty {
                    MVCard {
                        Text(event.notes).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                }
                if let linkedAlbum {
                    MVCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Label(linkedAlbum.name, systemImage: "rectangle.stack.fill")
                                    .font(MVFont.headline)
                                Spacer()
                                NavigationLink {
                                    AlbumDetailView(album: linkedAlbum)
                                } label: {
                                    Text("Open Album")
                                        .font(.subheadline)
                                }
                            }
                            if albumItems.isEmpty {
                                Text("No photos or videos in this album yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(albumItems.prefix(12)) { item in
                                            Button {
                                                viewerItem = item
                                            } label: {
                                                MediaThumbnailView(item: item, pixelSize: 220)
                                                    .frame(width: 84, height: 84)
                                                    .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                }
                MVCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reminders").font(MVFont.headline)
                        ForEach(event.reminderDays.sorted(), id: \.self) { d in
                            Label(d == 0 ? "Same day" : "\(d) days before", systemImage: "bell.fill")
                                .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(event.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Edit") { showingEditor = true }
        }
        .sheet(isPresented: $showingEditor) { SpecialDayEditor(event: event) }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewerView(
                items: albumItems.isEmpty ? [item] : albumItems,
                selectedID: item.id,
                title: linkedAlbum?.name ?? event.title
            )
            .environmentObject(appState)
        }
    }
}
