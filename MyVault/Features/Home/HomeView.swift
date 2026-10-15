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
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var importError: String?

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
                            PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, matching: .any(of: [.images, .videos])) {
                                QuickActionLabel(symbol: "plus", title: "Add Photos")
                            }
                            QuickAction(symbol: "heart", title: "Special Day") { appState.selectedTab = .specialDays }
                            QuickAction(symbol: "folder", title: "Album") { appState.selectedTab = .vault }
                        }
                        .padding(.horizontal)
                        if isImporting {
                            ProgressView("Encrypting…").padding(.horizontal)
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
            .onChange(of: pickerItems) { _, items in importItems(items) }
            .alert("Import failed", isPresented: importErrorBinding) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private var importErrorBinding: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private func importItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isImporting = true
        Task {
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                    let isVideo = UIImage(data: data) == nil
                    let stored = try VaultStorageService.shared.storeEncrypted(data: data)
                    let hash = EncryptionService.sha256(data)
                    await MainActor.run {
                        let m = VaultMedia(
                            fileName: "Import \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))",
                            encryptedFileName: stored,
                            mediaType: isVideo ? "video" : "photo",
                            fileSize: data.count,
                            contentHash: hash
                        )
                        context.insert(m)
                    }
                } catch {
                    await MainActor.run { importError = "An item could not be imported." }
                }
            }
            await MainActor.run {
                try? context.save()
                isImporting = false
                pickerItems = []
                Haptics.success()
            }
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
