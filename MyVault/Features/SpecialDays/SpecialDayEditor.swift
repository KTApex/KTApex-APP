import SwiftUI
import SwiftData

struct SpecialDayEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \VaultAlbum.createdAt) private var albums: [VaultAlbum]
    @Query(sort: \VaultMedia.createdAt, order: .reverse) private var media: [VaultMedia]
    let existing: SpecialDay?

    @State private var title = ""
    @State private var date = Date()
    @State private var type: SpecialDayType = .birthday
    @State private var notes = ""
    @State private var repeatsYearly = true
    @State private var reminderDays: Set<Int> = [7, 1, 0]
    @State private var hour = 9
    @State private var minute = 0
    @State private var photoFileName: String?
    @State private var linkedAlbumID: String?
    @State private var showingCoverPicker = false
    @State private var error: String?

    private let options = [30, 14, 7, 3, 1, 0]

    init(event: SpecialDay?) {
        existing = event
        if let e = event {
            _title = State(initialValue: e.title)
            _date = State(initialValue: e.date)
            _type = State(initialValue: e.type)
            _notes = State(initialValue: e.notes)
            _repeatsYearly = State(initialValue: e.repeatsYearly)
            _reminderDays = State(initialValue: Set(e.reminderDays))
            _hour = State(initialValue: e.reminderTimeHour)
            _minute = State(initialValue: e.reminderTimeMinute)
            _photoFileName = State(initialValue: e.photoFileName)
            _linkedAlbumID = State(initialValue: e.linkedAlbumID)
        }
    }

    private var selectedCover: VaultMedia? {
        guard let key = photoFileName, !key.isEmpty else { return nil }
        return media.first { !$0.isInTrash && ($0.id == key || $0.encryptedFileName == key) }
    }

    private var livePhotos: [VaultMedia] {
        media.filter { !$0.isInTrash && !$0.isVideo }
    }

    var body: some View {
        NavigationStack {
            Form {
                eventSection
                memoriesSection
                reminderSection
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "New Special Day" : "Edit Special Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .sheet(isPresented: $showingCoverPicker) {
                SpecialDayCoverPickerSheet(
                    photos: livePhotos,
                    selectedKey: photoFileName,
                    onSelect: { chosen in
                        photoFileName = chosen.id
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var eventSection: some View {
        Section("Event") {
            TextField("Title", text: $title)
                .accessibilityLabel("Event title")
            DatePicker("Date", selection: $date, displayedComponents: .date)
            Picker("Type", selection: $type) {
                ForEach(SpecialDayType.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            Toggle("Repeats yearly", isOn: $repeatsYearly)
            TextField("Notes (optional)", text: $notes, axis: .vertical)
        }
    }

    @ViewBuilder
    private var memoriesSection: some View {
        Section {
            Button {
                showingCoverPicker = true
            } label: {
                HStack(spacing: 12) {
                    if let cover = selectedCover {
                        MediaThumbnailView(item: cover, pixelSize: 120)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cover Photo")
                                .foregroundStyle(.primary)
                            Text(cover.fileName.isEmpty ? "Selected from Vault" : cover.fileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Label("Choose Cover Photo", systemImage: "photo.badge.plus")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(livePhotos.isEmpty)

            if photoFileName != nil {
                Button("Remove Cover Photo", role: .destructive) {
                    photoFileName = nil
                }
            }

            Picker("Linked Album", selection: $linkedAlbumID) {
                Text("None").tag(String?.none)
                ForEach(AlbumEditor.sorted(albums)) { album in
                    Text(album.name).tag(String?.some(album.id))
                }
            }
        } header: {
            Text("Memories")
        } footer: {
            Text("Link a vault photo or album to view all memories for this special day in one place.")
        }
    }

    @ViewBuilder
    private var reminderSection: some View {
        Section("Reminders") {
            ForEach(options, id: \.self) { d in
                Toggle(remindLabel(d), isOn: reminderBinding(for: d))
            }
            DatePicker(
                "Reminder time",
                selection: Binding<Date>(
                    get: { Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date() },
                    set: { newValue in
                        hour = Calendar.current.component(.hour, from: newValue)
                        minute = Calendar.current.component(.minute, from: newValue)
                    }
                ),
                displayedComponents: .hourAndMinute
            )
        }
    }

    private func reminderBinding(for day: Int) -> Binding<Bool> {
        Binding<Bool>(
            get: { reminderDays.contains(day) },
            set: { isOn in
                if isOn { reminderDays.insert(day) } else { reminderDays.remove(day) }
            }
        )
    }

    private func remindLabel(_ d: Int) -> String {
        d == 0 ? "Same day" : "\(d) \(d == 1 ? "day" : "days") before"
    }

    private func save() {
        guard !title.isBlank else { error = "Please give this day a title."; return }
        let event: SpecialDay
        if let existing {
            event = existing
        } else {
            event = SpecialDay(title: "", date: Date())
            context.insert(event)
        }
        event.title = title.trimmingCharacters(in: .whitespaces)
        event.date = date
        event.typeRaw = type.rawValue
        event.notes = notes
        event.repeatsYearly = repeatsYearly
        event.reminderDays = Array(reminderDays).sorted()
        event.reminderTimeHour = hour
        event.reminderTimeMinute = minute
        event.photoFileName = photoFileName
        event.linkedAlbumID = linkedAlbumID
        do {
            try context.save()
            Haptics.success()
            refreshWidgetSummary()
            Task { await NotificationService.shared.scheduleReminders(for: event) }
            dismiss()
        } catch {
            self.error = "Could not save. Please try again."
        }
    }

    private func refreshWidgetSummary() {
        let all = (try? context.fetch(FetchDescriptor<SpecialDay>())) ?? []
        WidgetSummaryService.refresh(events: all)
    }
}

private struct SpecialDayCoverPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let photos: [VaultMedia]
    let selectedKey: String?
    let onSelect: (VaultMedia) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 8)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if photos.isEmpty {
                    MVEmptyState(
                        symbol: "photo.on.rectangle",
                        title: "No vault photos yet",
                        subtitle: "Import photos into your vault first to pick a cover photo."
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(photos) { photo in
                                let isChosen = photo.id == selectedKey || photo.encryptedFileName == selectedKey
                                Button {
                                    Haptics.selection()
                                    onSelect(photo)
                                    dismiss()
                                } label: {
                                    ZStack(alignment: .bottomTrailing) {
                                        MediaThumbnailView(item: photo, pixelSize: 240)
                                            .frame(height: 104)
                                            .frame(maxWidth: .infinity)
                                            .clipShape(RoundedRectangle(cornerRadius: MVRadius.s, style: .continuous))
                                        if isChosen {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.white, Color.accentColor)
                                                .padding(6)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .navigationTitle("Choose Cover Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
