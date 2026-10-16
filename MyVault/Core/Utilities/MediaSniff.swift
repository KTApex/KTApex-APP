import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Which kind of media a blob of bytes is, as far as we can tell from the bytes.
enum MediaKind: String, Equatable {
    case image
    case video
}

struct MediaSniffResult: Equatable {
    let kind: MediaKind
    /// Lowercase extension **without** a leading dot.
    let fileExtension: String
}

/// Content sniffing for imported and exported media.
///
/// Import and share both have to answer the same two questions about bytes that
/// arrive without a useful file name: is this a photo or a video, and what
/// extension will other apps recognise? Answering from the bytes themselves (not
/// from the picker's declared content type, which the transfer can drop) means a
/// share export is named correctly even when the original name was lost, and a
/// truncated or damaged pick is rejected before it is written into the vault.
enum MediaSniff {

    static func sniff(_ data: Data) -> MediaSniffResult? {
        if let image = imageResult(data) { return image }
        if let video = videoResult(data) { return video }
        return nil
    }

    static func isImage(_ data: Data) -> Bool { imageResult(data) != nil }

    // MARK: - Images

    /// ImageIO decodes every format the system understands (HEIC, HEIF, JPEG,
    /// PNG, GIF, TIFF, RAW…), so let it decide and report the matching UTI.
    static func imageResult(_ data: Data) -> MediaSniffResult? {
        guard data.count >= 4,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) else { return nil }
        let identifier = type as String
        let ext = conventionalExtension(for: identifier) ?? fallbackImageExtension(data)
        return MediaSniffResult(kind: .image, fileExtension: ext.lowercased())
    }

    /// Apple's UTI table prefers "jpeg"/"heif"; Photos, AirDrop and most share
    /// targets expect "jpg"/"heic", so normalise the two that differ and leave
    /// every other format to the system table.
    private static func conventionalExtension(for identifier: String) -> String? {
        switch identifier {
        case "public.jpeg": return "jpg"
        case "public.heic", "public.heif": return "heic"
        default: return UTType(identifier)?.preferredFilenameExtension
        }
    }

    /// Used only if a decodable image reports a UTI we cannot map to an
    /// extension; JPEG is the safe container for a still image.
    private static func fallbackImageExtension(_ data: Data) -> String {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        return data.starts(with: png) ? "png" : "jpg"
    }

    // MARK: - Videos

    static func videoResult(_ data: Data) -> MediaSniffResult? {
        guard let ext = isoBaseMediaExtension(data) else { return nil }
        return MediaSniffResult(kind: .video, fileExtension: ext)
    }

    /// MP4/MOV/3GP files are ISO base media files: a `ftyp` box whose major brand
    /// (the four bytes after "ftyp") names the exact container.
    static func isoBaseMediaExtension(_ data: Data) -> String? {
        guard data.count >= 12 else { return nil }
        let header = [UInt8](data.prefix(12))
        guard let atom = String(bytes: header[4..<8], encoding: .ascii), atom == "ftyp" else { return nil }
        let brand = String(bytes: header[8..<12], encoding: .ascii) ?? ""
        switch brand {
        case "qt  ": return "mov"
        case "3gp4", "3gp5", "3gp6", "3gg6", "3g2a", "3g2b": return "3gp"
        default: return "mp4"
        }
    }

    /// Best-effort extension for a stored media row, used where the bytes are not
    /// available (for example a video thumbnail request).
    static func fileExtension(forMediaType type: String) -> String {
        type == "video" ? "mov" : "jpg"
    }
}

/// File names for media that leaves (or enters) the vault.
///
/// The vault intentionally keeps its own identifiers, but names that reach other
/// apps have to survive being written to a real file system: path separators,
/// colons, control characters and anything that makes a hidden or truncated file
/// are removed, and the extension always comes from sniffed bytes rather than
/// from whatever string the transfer happened to carry.
enum MediaFileName {

    private static let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        .union(.controlCharacters)
        .union(.newlines)

    /// A conservative stem: no path separators, no leading dot, no trailing dot
    /// or space, at most 80 characters.
    static func stem(_ raw: String) -> String {
        var value = raw.components(separatedBy: illegal).joined(separator: "-")
        value = value.replacingOccurrences(of: "..", with: "-")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") || value.hasSuffix(" ") { value.removeLast() }
        if value.count > 80 { value = String(value.prefix(80)) }
        while value.hasSuffix(".") || value.hasSuffix(" ") { value.removeLast() }
        // A name made entirely of punctuation ("///" → "---") is legal on disk but
        // useless to the user, so treat it as no name at all.
        if !value.contains(where: { $0.isLetter || $0.isNumber }) { value = "" }
        return value
    }

    static func sanitized(_ raw: String, fileExtension: String) -> String {
        var base = stem(raw)
        if let dot = base.lastIndex(of: ".") {
            let existing = String(base[base.index(after: dot)...])
            // Drop a trailing extension-looking suffix so we never end up with
            // "photo.heic.heic" or a double extension.
            if !existing.isEmpty, existing.count <= 6, existing != fileExtension {
                base = String(base[base.startIndex..<dot])
                base = stem(base)
            }
        }
        if base.isEmpty { base = "MyVault" }
        return fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
    }

    /// `MyVault_2026-10-16_15-45-30.heic` — derived from the real capture date so
    /// the exported name is meaningful without inventing metadata.
    static func generated(capturedAt: Date?, fileExtension: String) -> String {
        let date = capturedAt ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = formatter.string(from: date)
        return fileExtension.isEmpty ? "MyVault_\(stamp)" : "MyVault_\(stamp).\(fileExtension)"
    }

    /// Chooses the best available name for an item: the original Photos file name
    /// when the library exposed one, otherwise a date-stamped name.
    static func resolve(suggested: String?, capturedAt: Date?, fileExtension: String) -> String {
        if let suggested, !suggested.isBlank {
            let candidate = sanitized(suggested, fileExtension: fileExtension)
            if !candidate.isBlank, candidate != fileExtension { return candidate }
        }
        return generated(capturedAt: capturedAt, fileExtension: fileExtension)
    }
}
