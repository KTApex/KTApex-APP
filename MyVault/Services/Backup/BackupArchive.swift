import Foundation
import CryptoKit
import Compression

/// Something to write into a backup.
struct BackupEntry {
    enum Source {
        /// Small payload already in memory (the manifest).
        case data(Data)
        /// Large payload streamed from disk, never loaded whole (vault ciphertext
        /// of a video).
        case file(URL, byteCount: Int)
    }

    var name: String
    var source: Source
    /// Only ever true for small entries: media is already compressed, so spending
    /// CPU on it would make backup creation slower for no gain.
    var compress: Bool = false
}

/// Streaming reader/writer for the `.mvbackup` container.
///
/// Both directions work one part at a time, so memory use is bounded by
/// `BackupFormat.partSize` regardless of how large the vault is. All validation
/// happens before anything is committed, and every name that reaches this layer is
/// treated as untrusted: staged files are written under generated names derived from
/// the entry *index*, never from the name stored in the file, so a malicious backup
/// cannot write outside the staging directory.
enum BackupArchive {

    struct WriteResult {
        var url: URL
        var entryCount: Int
        var byteCount: Int
    }

    struct ReadResult {
        var header: BackupHeader
        /// Entry name → staged file, in the order the entries appeared.
        var stagedFiles: [String: URL]
        var totalPayloadBytes: Int
    }

    // MARK: - Writing

    @discardableResult
    static func write(
        entries: [BackupEntry],
        password: String,
        to url: URL,
        iterations: UInt32 = BackupFormat.defaultIterations,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> WriteResult {
        guard !entries.isEmpty else { throw BackupError.failedToWrite }
        guard iterations >= BackupFormat.minimumIterations,
              iterations <= BackupFormat.maximumIterations else { throw BackupError.corrupted }

        let salt = try BackupCrypto.randomSalt()
        let header = BackupHeader(
            formatVersion: BackupFormat.currentVersion,
            kdf: BackupFormat.kdfPBKDF2SHA256,
            iterations: iterations,
            salt: salt
        )
        let headerBytes = header.bytes
        let key = try BackupCrypto.deriveKey(password: password, salt: salt, iterations: iterations)

        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { try? manager.removeItem(at: url) }
        guard manager.createFile(atPath: url.path, contents: nil) else { throw BackupError.failedToWrite }
        // The container is already ciphertext, but it still gets complete protection
        // so a locked device cannot read the backup file at all.
        try? manager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)

        let handle = try FileHandle(forWritingTo: url)
        var totalWritten = 0
        do {
            try handle.write(contentsOf: headerBytes)
            try handle.write(contentsOf: BackupHeader.bigEndianBytes(UInt32(entries.count)))
            totalWritten += headerBytes.count + 4

            let plannedBytes = entries.reduce(0) { $0 + estimatedPayloadSize(of: $1) }
            var processedBytes = 0

            for (index, entry) in entries.enumerated() {
                if isCancelled() { throw BackupError.cancelled }
                totalWritten += try writeEntry(
                    entry,
                    index: UInt32(index),
                    key: key,
                    header: headerBytes,
                    handle: handle,
                    processedBytes: &processedBytes,
                    plannedBytes: max(plannedBytes, 1),
                    progress: progress
                )
            }
            try handle.synchronize()
            try handle.close()
            return WriteResult(url: url, entryCount: entries.count, byteCount: totalWritten)
        } catch {
            try? handle.close()
            try? manager.removeItem(at: url)
            throw error
        }
    }

    private static func estimatedPayloadSize(of entry: BackupEntry) -> Int {
        switch entry.source {
        case .data(let data): return data.count
        case .file(_, let byteCount): return byteCount
        }
    }

    /// Returns the number of bytes written for this entry.
    private static func writeEntry(
        _ entry: BackupEntry,
        index: UInt32,
        key: SymmetricKey,
        header: Data,
        handle: FileHandle,
        processedBytes: inout Int,
        plannedBytes: Int,
        progress: ((Double) -> Void)?
    ) throws -> Int {
        let nameBytes = Array(entry.name.utf8)
        guard nameBytes.count <= BackupFormat.Limits.maximumNameLength, !nameBytes.isEmpty else {
            throw BackupError.failedToWrite
        }

        // Resolve the payload: compression only ever applies to in-memory entries.
        var payloadData: Data?
        var payloadFile: URL?
        var payloadLength = 0
        var uncompressedLength = 0
        var flags: UInt8 = 0

        switch entry.source {
        case .data(let data):
            uncompressedLength = data.count
            if entry.compress, let compressed = BackupCompression.compress(data), compressed.count < data.count {
                payloadData = compressed
                flags = 1
            } else {
                payloadData = data
            }
            payloadLength = payloadData?.count ?? 0
        case .file(let url, let byteCount):
            payloadFile = url
            uncompressedLength = byteCount
            payloadLength = byteCount
        }

        let partCount = partCount(forPayloadLength: payloadLength)
        var metadata = Data([flags])
        metadata.append(contentsOf: BackupHeader.bigEndianBytes(UInt16(nameBytes.count)))
        metadata.append(contentsOf: nameBytes)
        metadata.append(contentsOf: BackupHeader.bigEndianBytes(UInt64(uncompressedLength)))
        metadata.append(contentsOf: BackupHeader.bigEndianBytes(UInt32(partCount)))
        try handle.write(contentsOf: metadata)
        var written = metadata.count

        // Sealed parts.
        var partIndex: UInt32 = 0
        if let payloadData {
            var offset = 0
            repeat {
                let end = min(offset + BackupFormat.partSize, payloadData.count)
                let slice = payloadData.subdata(in: offset..<end)
                written += try writePart(
                    slice, key: key, header: header, entryIndex: index, partIndex: partIndex, handle: handle
                )
                offset = end
                partIndex += 1
            } while offset < payloadData.count
            // Progress counts source bytes, not written bytes: a compressed entry
            // writes fewer bytes than it consumed, and the bar still has to reach
            // the end of the work.
            processedBytes += uncompressedLength
            progress?(min(Double(processedBytes) / Double(plannedBytes), 1))
        } else if let payloadFile {
            let reader = try FileHandle(forReadingFrom: payloadFile)
            defer { try? reader.close() }
            var remaining = payloadLength
            repeat {
                let chunk = try reader.read(upToCount: min(BackupFormat.partSize, max(remaining, 1))) ?? Data()
                if chunk.isEmpty && remaining > 0 { throw BackupError.failedToWrite }
                written += try writePart(
                    chunk, key: key, header: header, entryIndex: index, partIndex: partIndex, handle: handle
                )
                remaining -= chunk.count
                partIndex += 1
                processedBytes += chunk.count
                progress?(min(Double(processedBytes) / Double(plannedBytes), 1))
            } while remaining > 0
        }

        return written
    }

    private static func partCount(forPayloadLength length: Int) -> Int {
        guard length > 0 else { return 1 }
        return max(1, (length + BackupFormat.partSize - 1) / BackupFormat.partSize)
    }

    private static func writePart(
        _ plaintext: Data,
        key: SymmetricKey,
        header: Data,
        entryIndex: UInt32,
        partIndex: UInt32,
        handle: FileHandle
    ) throws -> Int {
        let aad = BackupCrypto.associatedData(header: header, entryIndex: entryIndex, partIndex: partIndex)
        let sealed = try BackupCrypto.seal(plaintext, key: key, associatedData: aad)
        try handle.write(contentsOf: BackupHeader.bigEndianBytes(UInt32(sealed.count)))
        try handle.write(contentsOf: sealed)
        return 4 + sealed.count
    }

    // MARK: - Reading

    /// Decrypts the whole container into `directory` (one file per entry) and
    /// returns the staged files. Nothing outside `directory` is touched.
    /// - Parameter entryLimit: stops after this many entries. Used to decrypt only
    ///   the manifest for a preview, without paying for the whole payload.
    static func read(
        from url: URL,
        password: String,
        into directory: URL,
        entryLimit: Int? = nil,
        progress: ((Double) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) throws -> ReadResult {
        let totalFileSize = max((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 1)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        // --- Header (validated, then used as authenticated data) ---
        let fixed = try BackupIO.exactly(handle, BackupFormat.headerFixedLength)
        guard fixed.count == BackupFormat.headerFixedLength else { throw BackupError.notABackupFile }
        guard Array(fixed.prefix(4)) == BackupFormat.magic else { throw BackupError.notABackupFile }
        let saltLength = Int(BackupHeader.readUInt16(fixed, at: 12))
        guard saltLength >= BackupFormat.minimumSaltLength,
              saltLength <= BackupFormat.maximumSaltLength else { throw BackupError.corrupted }
        let salt = try BackupIO.exactly(handle, saltLength)
        guard salt.count == saltLength else { throw BackupError.corrupted }
        var headerBytes = fixed
        headerBytes.append(salt)
        let header = try BackupHeader.parse(headerBytes)

        let key = try BackupCrypto.deriveKey(password: password, salt: header.salt, iterations: header.iterations)

        // --- Entry table ---
        let countData = try BackupIO.exactly(handle, 4)
        guard countData.count == 4 else { throw BackupError.corrupted }
        let entryCount = Int(BackupHeader.readUInt32(countData, at: 0))
        guard entryCount > 0, entryCount <= BackupFormat.Limits.maximumEntries else { throw BackupError.corrupted }

        var staged: [String: URL] = [:]
        var totalPayload = 0

        for entryIndex in 0..<entryCount {
            if let entryLimit, entryIndex >= entryLimit { break }
            if isCancelled() { throw BackupError.cancelled }

            let entryHeader = try BackupIO.exactly(handle, 1)
            guard let flags = entryHeader.first else { throw BackupError.corrupted }

            let nameLengthData = try BackupIO.exactly(handle, 2)
            guard nameLengthData.count == 2 else { throw BackupError.corrupted }
            let nameLength = Int(BackupHeader.readUInt16(nameLengthData, at: 0))
            guard nameLength > 0, nameLength <= BackupFormat.Limits.maximumNameLength else {
                throw BackupError.corrupted
            }
            let nameData = try BackupIO.exactly(handle, nameLength)
            guard nameData.count == nameLength,
                  let name = String(data: nameData, encoding: .utf8) else { throw BackupError.corrupted }
            // Names are never used as paths, but an obvious traversal attempt means
            // the file was not produced by MyVault.
            guard !name.contains("/"), !name.contains("\\"), !name.contains(".."), !name.contains("\0") else {
                throw BackupError.corrupted
            }

            let sizeData = try BackupIO.exactly(handle, 8)
            guard sizeData.count == 8 else { throw BackupError.corrupted }
            let uncompressedLength = BackupHeader.readUInt64(sizeData, at: 0)
            guard uncompressedLength <= UInt64(BackupFormat.Limits.maximumMediaBytes) else {
                throw BackupError.corrupted
            }

            let partsData = try BackupIO.exactly(handle, 4)
            guard partsData.count == 4 else { throw BackupError.corrupted }
            let partCount = Int(BackupHeader.readUInt32(partsData, at: 0))
            // A part can decrypt to at most partSize bytes.
            let maximumParts = Int((uncompressedLength / UInt64(BackupFormat.partSize))) + 2
            guard partCount >= 1, partCount <= maximumParts else { throw BackupError.corrupted }

            // Staged file name comes from the entry index, never from `name`.
            let stagedURL = directory.appendingPathComponent("entry-\(entryIndex)")
            guard FileManager.default.createFile(atPath: stagedURL.path, contents: nil) else {
                throw BackupError.outOfSpace
            }
            // Staging holds *plaintext*, so it gets the same protection as the vault
            // itself and lives in scratch space that is excluded from backups.
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: stagedURL.path
            )
            let writer = try FileHandle(forWritingTo: stagedURL)
            var entryBytes = 0
            do {
                for partIndex in 0..<partCount {
                    if isCancelled() { throw BackupError.cancelled }
                    let lengthData = try BackupIO.exactly(handle, 4)
                    guard lengthData.count == 4 else { throw BackupError.corrupted }
                    let sealedLength = Int(BackupHeader.readUInt32(lengthData, at: 0))
                    // 12-byte nonce + 16-byte tag plus the plaintext part.
                    guard sealedLength > 0, sealedLength <= BackupFormat.partSize + 64 else {
                        throw BackupError.corrupted
                    }
                    let sealed = try BackupIO.exactly(handle, sealedLength)
                    guard sealed.count == sealedLength else { throw BackupError.corrupted }

                    let aad = BackupCrypto.associatedData(header: headerBytes, entryIndex: UInt32(entryIndex), partIndex: UInt32(partIndex))
                    let plaintext = try BackupCrypto.open(sealed, key: key, associatedData: aad)
                    try writer.write(contentsOf: plaintext)
                    entryBytes += plaintext.count
                }
                try writer.synchronize()
                try writer.close()
            } catch {
                try? writer.close()
                throw error
            }

            // Uncompressed entries carry their payload verbatim, so the staged
            // size must equal the recorded size. Compressed entries hold the
            // *compressed* size here; their true size is validated against
            // `uncompressedLength` after decompression below.
            if flags & 1 == 0 {
                guard UInt64(entryBytes) == uncompressedLength else { throw BackupError.corrupted }
            }
            totalPayload += entryBytes
            guard totalPayload <= BackupFormat.Limits.maximumTotalBytes else { throw BackupError.corrupted }

            if flags & 1 == 1 {
                // Compressed entry: expand it in place with a hard size cap so a
                // crafted "bomb" cannot exhaust memory.
                let compressed = try Data(contentsOf: stagedURL)
                guard compressed.count == entryBytes else { throw BackupError.corrupted }
                let expanded = try BackupCompression.decompress(compressed, limit: BackupFormat.Limits.maximumDecompressedEntry)
                guard expanded.count == Int(uncompressedLength) else { throw BackupError.corrupted }
                try expanded.write(to: stagedURL, options: [.atomic, .completeFileProtection])
            }

            staged[name] = stagedURL
            progress?(min(Double(totalPayload) / Double(totalFileSize), 1))
        }

        if entryLimit == nil {
            // The container ends exactly after the last entry: anything more
            // means the file was appended to or tampered with. Limited reads
            // stop early on purpose, so only a full read enforces this.
            let trailing = try handle.read(upToCount: 1) ?? Data()
            guard trailing.isEmpty else { throw BackupError.corrupted }
        }

        return ReadResult(header: header, stagedFiles: staged, totalPayloadBytes: totalPayload)
    }
}

/// Small reading helpers shared by the archive reader.
enum BackupIO {
    /// Reads exactly `count` bytes, or fewer only at end of file.
    static func exactly(_ handle: FileHandle, _ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data()
        while data.count < count {
            let chunk = try handle.read(upToCount: count - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }
}

/// Entry-level compression, using Foundation's own zlib support.
enum BackupCompression {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let compressed = try? (data as NSData).compressed(using: .zlib) else { return nil }
        return compressed as Data
    }

    /// Decompresses with a hard ceiling on the result, so a small crafted entry
    /// cannot expand into hundreds of megabytes. Inflation is streamed: output
    /// is produced in 64 KiB chunks and the operation is aborted the moment the
    /// running total passes the cap, so even a ~1000:1 zlib bomb never gets to
    /// allocate more than the limit plus one chunk.
    static func decompress(_ data: Data, limit: Int) throws -> Data {
        guard !data.isEmpty, data.count <= limit else { throw BackupError.corrupted }

        var stream = compression_stream()
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw BackupError.corrupted
        }
        defer { compression_stream_end(&stream) }

        var output = Data()
        output.reserveCapacity(min(data.count * 4, limit))
        var status = COMPRESSION_STATUS_OK
        data.withUnsafeBytes { rawBuffer in
            stream.src_ptr = rawBuffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
            stream.src_size = data.count
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
            defer { chunk.deallocate() }
            repeat {
                stream.dst_ptr = chunk
                stream.dst_size = 64 * 1024
                status = compression_stream_process(&stream, COMPRESSION_STREAM_FINALIZE)
                output.append(chunk, count: 64 * 1024 - stream.dst_size)
                if output.count > limit { break }
            } while status == COMPRESSION_STATUS_OK
        }
        // The only acceptable end state is a clean finish at or under the cap.
        guard status == COMPRESSION_STATUS_END, output.count <= limit else { throw BackupError.corrupted }
        return output
    }
}
