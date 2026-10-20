import SwiftUI
import SwiftData
import PhotosUI
import UniformTypeIdentifiers
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
    @State private var showingCamera = false
    @State private var showingFileImporter = false
    @State private var notice: ImportCoordinator.Notice?
    @State private var noteCount = 0
    @State private var securityEvents: [PINService.SecurityEvent] = []

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h { case 0..<12: return "Good morning"; case 12..<17: return "Good afternoon"; default: return "Good evening" }
    }

    private var visibleMedia: [VaultMedia] {
        appState.isDecoyMode ? [] : media
    }

    private var visibleAlbums: [VaultAlbum] {
        appState.isDecoyMode ? [] : albums
    }

    private var nextEvent: SpecialDay? {
        guard !appState.isDecoyMode else { return nil }
        return events.filter { CountdownEngine.nextOccurrence(of: $0).daysRemaining >= 0 }
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

                    if !appState.isDecoyMode, let latestEvent = securityEvents.first {
                        MVCard {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundStyle(.red)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("SECURITY ALERT · \(securityEvents.count) \(securityEvents.count == 1 ? "EVENT" : "EVENTS")")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.red)
                                    Text(latestEvent.note ?? "Failed PIN unlock attempt")
                                        .font(MVFont.headline)
                                    Text(latestEvent.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Dismiss") {
                                    PINService.shared.clearSecurityEvents()
                                    securityEvents = []
                                    Haptics.tap()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal)
                    }

                    MVCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("PRIVATE VAULT", systemImage: "lock.shield.fill")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text("\(visibleMedia.filter { !$0.isVideo && !$0.isInTrash }.count) Photos")
                                Text("·")
                                Text("\(visibleMedia.filter { $0.isVideo && !$0.isInTrash }.count) Videos")
                                Text("·")
                                Text("\(appState.isDecoyMode ? 0 : noteCount) Notes")
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
                                HStack(spacing: 12) {
                                    if let cover = event.coverMedia(in: visibleMedia) {
                                        MediaThumbnailView(item: cover, pixelSize: 120)
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))
                                    } else {
                                        Image(systemName: event.type.symbol).foregroundStyle(.tint)
                                    }
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
                            QuickAction(symbol: "folder", title: "Album") { appState.openAlbums() }
                        }
                        .padding(.horizontal)
                        HStack(spacing: 12) {
                            if SecureCameraPicker.isCameraAvailable {
                                QuickAction(symbol: "camera.fill", title: "Camera") { showingCamera = true }
                            }
                            QuickAction(symbol: "doc.badge.plus", title: "Files") { showingFileImporter = true }
                            QuickAction(symbol: "lock.doc.fill", title: "Notes") { appState.openNotes() }
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

                    if !visibleAlbums.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Recent Albums").font(MVFont.headline).padding(.horizontal)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(visibleAlbums.prefix(10)) { album in
                                        NavigationLink {
                                            AlbumDetailView(album: album)
                                        } label: {
                                            AlbumCard(album: album)
                                                .frame(width: 160)
                                        }
                                        .buttonStyle(.plain)
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
            .onAppear {
                noteCount = appState.isDecoyMode ? 0 : SecureNoteService.shared.loadAll().count
                securityEvents = appState.isDecoyMode ? [] : PINService.shared.securityEvents()
            }
            .photosPicker(isPresented: $showingPicker, selection: $pickerItems, maxSelectionCount: 50, matching: .any(of: [.images, .videos]))
            .fullScreenCover(isPresented: $showingCamera) {
                SecureCameraPicker { payload in
                    importer.startPayloads([payload], label: "Encrypting camera capture", context: context, album: nil)
                }
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.image, .movie, .pdf],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result, !urls.isEmpty {
                    importer.startFiles(urls, context: context, album: nil)
                }
            }
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
