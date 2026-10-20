import Foundation

/// A private note encrypted at rest with AES-256-GCM using the vault key.
///
/// Both the title and body live inside the encrypted `.mvnote` file so no plaintext
/// note content ever touches an unencrypted database or `UserDefaults`.
struct SecureNote: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var body: String
    var isPinned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: String = UUID().uuidString,
        title: String,
        body: String,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = body
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return firstLine.isEmpty ? "Untitled Note" : firstLine
    }
}

/// Manages AES-256-GCM encrypted `.mvnote` files on disk.
final class SecureNoteService {
    static let shared = SecureNoteService()

    let notesDirectory: URL

    init(directory: URL? = nil) {
        if let directory {
            notesDirectory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            notesDirectory = base.appendingPathComponent("VaultNotes", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: notesDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = false
        var mutable = notesDirectory
        try? mutable.setResourceValues(rv)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func loadAll() -> [SecureNote] {
        guard let key = try? KeychainService.shared.vaultKey() else { return [] }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: notesDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        var loaded: [SecureNote] = []
        for url in urls where url.pathExtension == "mvnote" {
            guard let ciphertext = try? Data(contentsOf: url),
                  let plaintext = try? EncryptionService.shared.decrypt(ciphertext, key: key),
                  let note = try? Self.decoder.decode(SecureNote.self, from: plaintext) else {
                continue
            }
            loaded.append(note)
        }
        return Self.sorted(loaded)
    }

    @discardableResult
    func save(_ note: SecureNote) throws -> SecureNote {
        let key = try KeychainService.shared.vaultKey()
        let plaintext = try Self.encoder.encode(note)
        let ciphertext = try EncryptionService.shared.encrypt(plaintext, key: key)
        let url = fileURL(for: note.id)
        try ciphertext.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return note
    }

    func delete(id: String) {
        let url = fileURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }

    /// Merges restored notes into the encrypted note store without overwriting
    /// existing notes that share the same ID.
    @discardableResult
    func mergeRestored(_ incoming: [SecureNote]) throws -> Int {
        guard !incoming.isEmpty else { return 0 }
        let existingIDs = Set(loadAll().map(\.id))
        var restored = 0
        for note in incoming where !existingIDs.contains(note.id) {
            try save(note)
            restored += 1
        }
        return restored
    }

    static func sorted(_ notes: [SecureNote]) -> [SecureNote] {
        notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    static func matches(_ note: SecureNote, search: String) -> Bool {
        guard !search.isBlank else { return true }
        let needle = GalleryComposer.folded(search.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return true }
        return GalleryComposer.folded(note.title).contains(needle)
            || GalleryComposer.folded(note.body).contains(needle)
    }

    private func fileURL(for id: String) -> URL {
        let safeID = id.replacingOccurrences(of: "/", with: "_")
        return notesDirectory.appendingPathComponent("\(safeID).mvnote")
    }
}
