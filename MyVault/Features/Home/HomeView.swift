import SwiftUI
import SwiftData
import PhotosUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.modelContext) private var context
    @Query(sort: \VaultAlbum.createdAt) private var albums: [VaultAlbum]
    @Query(sort: \VaultMedia.createdAt, order: .reverse) private var media: [VaultMedia]
    @Query(sort: \SpecialDay.date) private var events: [SpecialDay]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var importer = ImportCoordinator()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingPicker = false
    @State private var notice: ImportCoordinator.Notice?

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h { case 0..<12: return "Good morning"; case 12..<17: return "Good afternoon"; default: return "Good evening" }
    }

    private var nextEvent: SpecialDay? {
        events.filter { CountdownEngine.nextOccurrence(of: $0).daysRemaining >= 0 }
            .sorted { CountdownEngine.nextOccurrence(of: $0).daysRemaining < CountdownEngine.nextOccurrence(of: $1).daysRemaining }
            .first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MyVault").font(MVFont.greeting)
                        Text(greeting).font(MVFont.body).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    MVCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("PRIVATE VAULT", systemImage: "lock.shield.fill")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text("\(media.filter { !$0.isVideo && !$0.isInTrash }.count) Photos")
                                Text("·")
                                Text("\(media.filter { $0.isVideo && !$0.isInTrash }.count) Videos")
                            }.font(MVFont.headline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)

                    if let event = nextEvent {
                        MVCard {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("NEXT SPECIAL DAY", systemImage: "heart.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Image(systemName: event.type.symbol).foregroundStyle(.tint)
                                    VStack(alignment: .leading) {
                                        Text(event.title).font(MVFont.headline)
                                        Text(CountdownEngine.headline(for: event))
                                            .font(MVFont.body).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("View") { appState.openSpecialDay(id: event.id) }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick Actions").font(MVFont.headline).padding(.horizontal)
                        HStack(spacing: 12) {
                            QuickAction(symbol: "plus", title: "Add Photos") { beginImport() }
                            QuickAction(symbol: "heart", title: "Special Day") { appState.selectedTab = .specialDays }
                            QuickAction(symbol: "folder", title: "Album") { appState.selectedTab = .vault }
                        }
                        .padding(.horizontal)
                        if importer.isWorking {
                            MVProgressCard(
                                title: importer.workingLabel,
                                detail: "Every item is encrypted and verified before it counts as imported.",
                                progress: importer.progress,
                                onCancel: importer.canCancel ? { importer.cancel() } : nil
                            )
                            .padding(.horizontal)
                        }
                    }

                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recent Albums").font(MVFont.headline).padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(albums.prefix(10)) { album in
                                        AlbumCard(album: album)
                                            .frame(width: 160)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Home")
            .photosPicker(isPresented: $showingPicker, selection: $pickerItems, maxSelectionCount: 50, matching: .any(of: [.images, .videos]))
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                importer.start(items, context: context, album: nil)
                pickerItems = []
            }
            .onChange(of: importer.notice) { _, newValue in
                if let newValue { notice = newValue }
            }
            .confirmationDialog(
                "Remove originals from Photos?",
                isPresented: removalBinding,
                titleVisibility: .visible,
                presenting: importer.removalRequest
            ) { request in
                Button(request.count == 1 ? "Remove Original" : "Remove \(request.count) Originals", role: .destructive) {
                    importer.confirmRemoval()
                }
                Button("Keep in Photos", role: .cancel) { importer.keepOriginals() }
            } message: { request in
                Text("\(request.count) \(request.count == 1 ? "item was" : "items were") encrypted into your vault and verified. The originals stay in Photos unless you remove them.")
            }
            .alert(notice?.title ?? "", isPresented: noticeBinding, presenting: notice) { value in
                if let actionTitle = value.actionTitle {
                    Button(actionTitle) {
                        importer.performNoticeAction()
                        notice = nil
                    }
                }
                Button("OK", role: .cancel) {
                    importer.dismissNotice()
                    notice = nil
                }
            } message: { value in
                Text(value.message)
            }
        }
    }

    private var removalBinding: Binding<Bool> {
        Binding(
            get: { importer.removalRequest != nil },
            set: { presented in
                guard !presented, importer.removalRequest != nil else { return }
                importer.keepOriginals()
            }
        )
    }

    private var noticeBinding: Binding<Bool> {
        Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })
    }

    private func beginImport() {
        Task {
            await importer.prepareForImport()
            showingPicker = true
        }
    }
}

private struct QuickActionLabel: View {
    let symbol: String
    let title: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: MVRadius.m))
        .accessibilityLabel(title)
    }
}

private struct QuickAction: View {
    let symbol: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            QuickActionLabel(symbol: symbol, title: title)
        }
    }
}
