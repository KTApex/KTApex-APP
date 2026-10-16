import Foundation

/// On-disk format for `.mvbackup` files.
///
/// A MyVault backup is **one encrypted stream**, not an archive of plaintext files
/// inside a container: there is no readable ZIP, no exposed folder structure and no
/// partially recoverable data without the password. The container is:
///
/// ```
/// "MVBK"            4 bytes   magic
/// formatVersion     1 byte    reject anything newer than we understand
/// kdf               1 byte    1 = PBKDF2-HMAC-SHA256
/// reserved          2 bytes   must be zero
/// iterations        4 bytes   big-endian PBKDF2 rounds (authenticated)
/// saltLength        2 bytes   big-endian
/// salt              n bytes   cryptographically random
/// ── body ────────────────────────────────  AES-GCM sealed parts
/// entryCount        4 bytes   inside the encrypted payload
/// entry*                      name, sizes, then one or more sealed parts
/// ```
///
/// The header is passed to AES-GCM as associated data for the first part of every
/// entry, so the format version, KDF parameters and salt cannot be altered without
/// breaking authentication. Each part also binds its entry and part index as
/// associated data, so reordering or duplicating parts is detected.
enum BackupFormat {
    static let magic: [UInt8] = Array("MVBK".utf8)
    /// Bumped only for changes a previous version cannot read safely.
    static let currentVersion: UInt8 = 1
    static let kdfPBKDF2SHA256: UInt8 = 1
    static let defaultIterations: UInt32 = 250_000
    /// Accepted PBKDF2 range. The lower bound rejects backups whose parameters
    /// would make guessing cheap; the upper bound stops a hostile file from
    /// turning a restore into a denial-of-service (a huge iteration count would
    /// spin the CPU for hours).
    static let minimumIterations: UInt32 = 10_000
    static let maximumIterations: UInt32 = 5_000_000
    static let saltLength = 32
    static let minimumSaltLength = 16
    static let maximumSaltLength = 64
    static let headerFixedLength = 14

    /// Plaintext size of one sealed part. Small enough that a multi-gigabyte file
    /// never has to exist in memory twice, large enough that the per-part AES-GCM
    /// tag and nonce overhead stays negligible.
    static let partSize = 4 * 1024 * 1024

    enum Limits {
        static let maximumEntries = 100_000
        static let maximumNameLength = 255
        /// An entry whose *decompressed* size exceeds this is refused. Backups only
        /// compress the manifest, and a 32 MiB manifest would be pathological, so
        /// this is a compression-bomb guard rather than a real limit.
        static let maximumDecompressedEntry = 32 * 1024 * 1024
        /// Sanity ceiling for one restored media item.
        static let maximumMediaBytes = 8 * 1024 * 1024 * 1024
        /// Ceiling for the whole decrypted payload, to bound work on malformed input.
        static let maximumTotalBytes = 200 * 1024 * 1024 * 1024
    }

    /// Name of the entry that carries the manifest. Always first, so a wrong
    /// password fails immediately instead of after copying gigabytes.
    static let manifestEntryName = "manifest.json"
}

/// Structurally valid header information, available *before* a password is known.
struct BackupHeader: Equatable {
    var formatVersion: UInt8
    var kdf: UInt8
    var iterations: UInt32
    var salt: Data

    var length: Int { BackupFormat.headerFixedLength + salt.count }

    var bytes: Data {
        var data = Data(BackupFormat.magic)
        data.append(formatVersion)
        data.append(kdf)
        data.append(contentsOf: [0, 0])
        data.append(contentsOf: Self.bigEndianBytes(iterations))
        data.append(contentsOf: Self.bigEndianBytes(UInt16(salt.count)))
        data.append(salt)
        return data
    }

    /// Validates everything that can be judged without the password. Throws
    /// `BackupError.unsupportedVersion` specifically, so the UI can tell the user
    /// their app is too old rather than that the file is corrupt.
    static func parse(_ data: Data) throws -> BackupHeader {
        guard data.count >= BackupFormat.headerFixedLength else { throw BackupError.notABackupFile }
        guard Array(data.prefix(4)) == BackupFormat.magic else { throw BackupError.notABackupFile }

        let version = data[4]
        guard version <= BackupFormat.currentVersion else {
            throw BackupError.unsupportedVersion(Int(version))
        }
        guard version >= 1 else { throw BackupError.notABackupFile }

        let kdf = data[5]
        guard kdf == BackupFormat.kdfPBKDF2SHA256 else { throw BackupError.unsupportedKeyDerivation }
        guard data[6] == 0, data[7] == 0 else { throw BackupError.corrupted }

        let iterations = Self.readUInt32(data, at: 8)
        guard iterations >= BackupFormat.minimumIterations, iterations <= BackupFormat.maximumIterations else {
            throw BackupError.corrupted
        }
        let saltLength = Int(Self.readUInt16(data, at: 12))
        guard saltLength >= BackupFormat.minimumSaltLength,
              saltLength <= BackupFormat.maximumSaltLength,
              data.count >= BackupFormat.headerFixedLength + saltLength else {
            throw BackupError.corrupted
        }
        let salt = data.subdata(in: BackupFormat.headerFixedLength..<(BackupFormat.headerFixedLength + saltLength))
        return BackupHeader(formatVersion: version, kdf: kdf, iterations: iterations, salt: salt)
    }

    /// Reads just enough of a file to describe it (used to show the version before
    /// asking for a password).
    static func readHeader(from url: URL) throws -> BackupHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: BackupFormat.headerFixedLength + BackupFormat.maximumSaltLength) ?? Data()
        return try parse(prefix)
    }

    // MARK: - Byte helpers

    static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 24),
         UInt8(truncatingIfNeeded: value >> 16),
         UInt8(truncatingIfNeeded: value >> 8),
         UInt8(truncatingIfNeeded: value)]
    }

    static func bigEndianBytes(_ value: UInt16) -> [UInt8] {
        [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    static func bigEndianBytes(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> (UInt64($0) * 8)) }
    }

    static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard data.count >= offset + 2 else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
    }

    static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        guard data.count >= offset + 8 else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        return value
    }
}

/// Failure modes of the backup engine.
///
/// The password-related cases deliberately share one message: a user who mistypes a
/// password and a user handing over a tampered file should learn the same thing, and
/// neither should learn anything about the backup's internal structure.
enum BackupError: LocalizedError, Equatable {
    case notABackupFile
    case unsupportedVersion(Int)
    case unsupportedKeyDerivation
    case corrupted
    case wrongPasswordOrDamaged
    case passwordTooShort
    case passwordMismatch
    case cancelled
    case outOfSpace
    case failedToWrite
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .notABackupFile:
            return "This file is not a MyVault backup."
        case .unsupportedVersion(let version):
            return "This backup was created by a newer version of MyVault (format \(version)). Update the app and try again."
        case .unsupportedKeyDerivation:
            return "This backup uses an encryption method this version of MyVault does not support."
        case .corrupted:
            return "This backup is damaged and cannot be read. Nothing on your device was changed."
        case .wrongPasswordOrDamaged:
            return "The backup could not be opened. The password may be incorrect, or the file may be damaged. Nothing on your device was changed."
        case .passwordTooShort:
            return "Choose a backup password of at least 8 characters."
        case .passwordMismatch:
            return "The passwords do not match."
        case .cancelled:
            return "The operation was cancelled. Nothing already stored in your vault was changed."
        case .outOfSpace:
            return "There is not enough free space to finish. Free up some storage and try again."
        case .failedToWrite:
            return "The backup file could not be written."
        case .restoreFailed(let reason):
            return reason
        }
    }
}
