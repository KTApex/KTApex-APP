import Foundation

/// Scratch space for plaintext that must exist on disk only briefly.
///
/// Sharing, exporting and importing all need real files that other APIs can read,
/// which is exactly the point where a vault app can accidentally leave decrypted
/// media on disk. Everything produced here is:
///
/// * written with `FileProtectionType.complete` (unreadable while the device is
///   locked), and
/// * excluded from backup, and
/// * created inside a per-operation directory so one `removeDirectory` call
///   cleans up every file the operation produced.
///
/// Cleanup is the caller's responsibility, but every helper here removes what it
/// created when it fails, so a thrown error never leaves a file behind.
enum SecureScratch {

    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MyVaultScratch", isDirectory: true)
    }

    /// Creates a private directory for one operation (prefix makes it obvious in
    /// a debugger which feature owns it).
    static func makeDirectory(prefix: String = "op") throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        applyProtection(to: directory)
        return directory
    }

    /// Writes plaintext into `directory` with complete file protection.
    static func write(_ data: Data, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        applyProtection(to: url)
        return url
    }

    /// Streams an existing file into scratch space without loading it into memory.
    static func copy(_ source: URL, named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        applyProtection(to: url)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes any scratch directory left behind by an earlier run (for example
    /// after the app was terminated mid-share).
    static func purgeStale() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries { removeDirectory(entry) }
    }

    private static func applyProtection(to url: URL) {
        // Best effort: the simulator ignores data-protection classes, and a file
        // that is already protected is not an error.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }
}
