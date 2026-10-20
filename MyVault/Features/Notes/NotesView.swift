import SwiftUI

/// Encrypted private notes screen.
///
/// Every note is stored as an AES-256-GCM `.mvnote` ciphertext file on disk. While
/// the vault is in Decoy Mode (`appState.isDecoyMode`), real notes are never loaded
/// and any note typed during the decoy session stays only in ephemeral memory.
struct NotesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var notes: [SecureNote] = []
    @State private var searchText = ""
    @State private var showingNew = false
    @State private var editingNote: SecureNote?
    @State private var alertMessage: String?

    private var visibleNotes: [SecureNote] {
        SecureNoteService.sorted(notes).filter {
            SecureNoteService.matches($0, search: searchText)
        }
    }

    var body: some View {
        Group {
            if notes.isEmpty {
                MVEmptyState(
                    symbol: "lock.doc.fill",
                    title: "No private notes yet",
                    subtitle: "Write private memories, passwords, or thoughts. Each note is encrypted with AES-256-GCM.",
                    actionTitle: "New Note",
                    action: { showingNew = true }
                )
            } else if visibleNotes.isEmpty {
                MVEmptyState(
                    symbol: "magnifyingglass",
                    title: "No matching notes",
                    subtitle: "No note contains “\(searchText)”.",
                    actionTitle: "Clear Search",
                    action: { searchText = "" }
                )
            } else {
                List {
                    ForEach(visibleNotes) { note in
                        Button {
                            editingNote = note
                        } label: {
                            NoteRow(note: note)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) {
                                delete(note)
                            }
                            Button(note.isPinned ? "Unpin" : "Pin") {
                                togglePin(note)
                            }
                            .tint(.accentColor)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Private Notes")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingNew = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("New private note")
            }
        }
        .onAppear { reload() }
        .onChange(of: appState.isDecoyMode) { _, _ in reload() }
        .sheet(isPresented: $showingNew) {
            NoteEditorSheet(existing: nil) { saved in
                persist(saved)
            }
        }
        .sheet(item: $editingNote) { note in
            NoteEditorSheet(existing: note) { saved in
                persist(saved)
            }
        }
        .alert("Note not saved", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func reload() {
        guard !appState.isDecoyMode else {
            notes = []
            return
        }
        notes = SecureNoteService.shared.loadAll()
    }

    private func persist(_ note: SecureNote) {
        if appState.isDecoyMode {
            if let idx = notes.firstIndex(where: { $0.id == note.id }) {
                notes[idx] = note
            } else {
                notes.insert(note, at: 0)
            }
            Haptics.success()
            return
        }
        do {
            try SecureNoteService.shared.save(note)
            notes = SecureNoteService.shared.loadAll()
            Haptics.success()
        } catch {
            Haptics.error()
            alertMessage = "The note could not be encrypted and saved."
        }
    }

    private func togglePin(_ note: SecureNote) {
        var updated = note
        updated.isPinned.toggle()
        updated.updatedAt = Date()
        persist(updated)
    }

    private func delete(_ note: SecureNote) {
        if appState.isDecoyMode {
            notes.removeAll { $0.id == note.id }
            Haptics.success()
            return
        }
        SecureNoteService.shared.delete(id: note.id)
        notes = SecureNoteService.shared.loadAll()
        Haptics.success()
    }
}

private struct NoteRow: View {
    let note: SecureNote

    private var previewText: String {
        let trimmed = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No additional text" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
                Text(note.displayTitle)
                    .font(MVFont.headline)
                    .lineLimit(1)
                Spacer()
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(previewText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(note.displayTitle), \(previewText)")
    }
}

private struct NoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let existing: SecureNote?
    let onSave: (SecureNote) -> Void

    @State private var title: String
    @State private var content: String
    @State private var isPinned: Bool

    init(existing: SecureNote?, onSave: @escaping (SecureNote) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _title = State(initialValue: existing?.title ?? "")
        _content = State(initialValue: existing?.body ?? "")
        _isPinned = State(initialValue: existing?.isPinned ?? false)
    }

    private var isBlank: Bool {
        title.isBlank && content.isBlank
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Note title", text: $title)
                        .accessibilityLabel("Note title")
                    Toggle("Pin to top", isOn: $isPinned)
                }
                Section("Encrypted Note") {
                    TextEditor(text: $content)
                        .frame(minHeight: 220)
                        .accessibilityLabel("Note body")
                }
            }
            .navigationTitle(existing == nil ? "New Note" : "Edit Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let now = Date()
                        let note = SecureNote(
                            id: existing?.id ?? UUID().uuidString,
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            body: content,
                            isPinned: isPinned,
                            createdAt: existing?.createdAt ?? now,
                            updatedAt: now
                        )
                        onSave(note)
                        dismiss()
                    }
                    .disabled(isBlank)
                }
            }
        }
    }
}
