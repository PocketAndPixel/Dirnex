import CryptoKit
import Foundation

// MARK: - Result

/// The digests of one file — one hex string per algorithm asked for, plus the byte count actually
/// read, so a caller can show "hashed 3.2 GB" without a second `stat`.
///
/// Ordering is `ChecksumAlgorithm.allCases`, never dictionary order, so a multi-algorithm display
/// or a written manifest comes out the same every run.
public struct ChecksumDigests: Sendable, Equatable {
    /// Bytes fed through the hashes. For a file read to EOF this is its size.
    public let byteSize: Int64

    private let hexByAlgorithm: [ChecksumAlgorithm: String]

    public init(byteSize: Int64, hexByAlgorithm: [ChecksumAlgorithm: String]) {
        self.byteSize = byteSize
        self.hexByAlgorithm = hexByAlgorithm
    }

    /// The lowercase hex digest for one algorithm, or `nil` if it wasn't among those computed.
    public subscript(algorithm: ChecksumAlgorithm) -> String? { hexByAlgorithm[algorithm] }

    /// The algorithms present, in `ChecksumAlgorithm.allCases` order.
    public var algorithms: [ChecksumAlgorithm] {
        ChecksumAlgorithm.allCases.filter { hexByAlgorithm[$0] != nil }
    }

    public var isEmpty: Bool { hexByAlgorithm.isEmpty }
}

// MARK: - Accumulator

/// The chunk-by-chunk half of the engine: feed it bytes from anywhere, ask it for digests at the
/// end.
///
/// Separated from the file-reading loop on purpose. A checksum over SFTP or FTP is a full download
/// (neither `sftp` nor `curl` can hash server-side), so the app hashes the stream *as it arrives*
/// rather than writing a temporary file and reading it back — and this is the piece that lets it,
/// with no path and no filesystem in sight. It is also what makes the engine testable against a
/// literal, with no temp tree at all.
///
/// **All N algorithms run in one pass.** The M14 probe measured all four together at ~247 MiB/s
/// combined, which is what makes "compute everything while the bytes are in hand" affordable and
/// means a file never has to be re-read to add a second algorithm later.
///
/// Not `Sendable`: it is a mutable value owned by whichever thread is doing the reading.
public struct ChecksumAccumulator {
    private var crc32: CRC32?
    private var md5: Insecure.MD5?
    private var sha1: Insecure.SHA1?
    private var sha256: SHA256?
    private var byteCount: Int64 = 0

    /// An accumulator running exactly the requested algorithms. An empty set is legal and digests
    /// nothing — the caller gets an empty ``ChecksumDigests`` with a byte count.
    public init(algorithms: Set<ChecksumAlgorithm>) {
        if algorithms.contains(.crc32) { crc32 = CRC32() }
        if algorithms.contains(.md5) { md5 = Insecure.MD5() }
        if algorithms.contains(.sha1) { sha1 = Insecure.SHA1() }
        if algorithms.contains(.sha256) { sha256 = SHA256() }
    }

    /// Fold one chunk into every running digest. Chunk boundaries never affect the result, so the
    /// caller is free to read in whatever sizes its transport hands over.
    public mutating func update(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        byteCount += Int64(chunk.count)
        crc32?.update(chunk)
        md5?.update(data: chunk)
        sha1?.update(data: chunk)
        sha256?.update(data: chunk)
    }

    /// The digests so far, as lowercase hex. Non-mutating and repeatable: reading it does not close
    /// the accumulator, so a caller may take an intermediate answer and keep feeding.
    public func finalized() -> ChecksumDigests {
        var hex: [ChecksumAlgorithm: String] = [:]
        if let crc32 { hex[.crc32] = crc32.hexDigest }
        if let md5 { hex[.md5] = Self.hexString(md5.finalize()) }
        if let sha1 { hex[.sha1] = Self.hexString(sha1.finalize()) }
        if let sha256 { hex[.sha256] = Self.hexString(sha256.finalize()) }
        return ChecksumDigests(byteSize: byteCount, hexByAlgorithm: hex)
    }

    private static func hexString(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Engine

/// Digests of an on-disk file (PLAN.md §M14 Slice 1), in `ByteComparator`'s shape exactly.
///
/// It touches bytes, so per PLAN.md §2 it lives in `DirnexCore` and is tested. The read is chunked
/// — never a whole file in memory — cancellation is polled between chunks, progress is reported
/// through the caller's callback, and the caller decides where it runs (the app drives it off the
/// main thread, on `FileOperationQueue`). Chunk size is 128 KiB, the same as `ByteComparator`'s and
/// for the same reason: the M14 probe measured throughput flat between 64 KiB and 4 MiB, so there
/// is nothing to tune.
public enum ChecksumEngine {
    /// The read size. Measured irrelevant between 64 KiB and 4 MiB, so it matches `ByteComparator`.
    public static let chunkSize = 128 * 1024

    /// Compute one or more digests of a local file in a single pass.
    ///
    /// - Parameters:
    ///   - path: Must be on the `.local` backend and a regular file (symlinks are followed, as
    ///     `shasum` does — the digest is of the target's bytes).
    ///   - algorithms: What to compute. All of them run over the same pass; an empty set reads
    ///     nothing and returns empty digests.
    ///   - allowDataless: Pass `true` only after the user has agreed to the download. By default a
    ///     `SF_DATALESS` placeholder throws ``ChecksumError/wouldDownloadPlaceholder(name:)``
    ///     instead of silently pulling the file out of iCloud or Google Drive — reading one byte
    ///     materializes it and blocks (docs/NOTES.md).
    ///   - onProgress: Called after each chunk with the *cumulative* byte count.
    ///   - isCancelled: Polled between chunks; throws `CancellationError` when it fires.
    ///
    /// - Throws: ``ChecksumError`` for the three guards above; `VFSError` for a read failure
    ///   (permission, vanished mid-read), normalized through `fromErrno` like the rest of the VFS
    ///   layer; `CancellationError` when abandoned.
    public static func digests(
        of path: VFSPath,
        using algorithms: Set<ChecksumAlgorithm> = [.recommended],
        chunkSize: Int = chunkSize,
        allowDataless: Bool = false,
        onProgress: (Int64) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> ChecksumDigests {
        guard path.backend == .local else { throw ChecksumError.needsLocalFile }
        let status = try statistics(of: path)
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw ChecksumError.needsRegularFile }
        guard allowDataless || (status.st_flags & UInt32(SF_DATALESS)) == 0 else {
            throw ChecksumError.wouldDownloadPlaceholder(name: path.lastComponent)
        }
        guard !algorithms.isEmpty else {
            return ChecksumDigests(byteSize: 0, hexByAlgorithm: [:])
        }

        let handle = try openForReading(path)
        defer { try? handle.close() }

        var accumulator = ChecksumAccumulator(algorithms: algorithms)
        var read: Int64 = 0
        while true {
            if isCancelled() { throw CancellationError() }
            let chunk = try readChunk(handle, upTo: chunkSize, at: path)
            if chunk.isEmpty { break }
            accumulator.update(chunk)
            read += Int64(chunk.count)
            onProgress(read)
        }
        return accumulator.finalized()
    }

    // MARK: - Helpers

    /// One `stat` answers all three questions the guards ask — regular file, size, and the
    /// `SF_DATALESS` flag — so the placeholder check costs nothing over the type check that had to
    /// happen anyway. `stat` rather than `lstat`, so a symlink is hashed as its target.
    private static func statistics(of path: VFSPath) throws -> stat {
        var status = stat()
        guard stat(path.path, &status) == 0 else {
            throw VFSError.fromErrno(errno, path: path)
        }
        return status
    }

    private static func openForReading(_ path: VFSPath) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: URL(fileURLWithPath: path.path))
        } catch {
            throw VFSError.fromErrno(errnoValue(from: error), path: path)
        }
    }

    private static func readChunk(
        _ handle: FileHandle,
        upTo count: Int,
        at path: VFSPath
    ) throws -> Data {
        do {
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw VFSError.fromErrno(errnoValue(from: error), path: path)
        }
    }

    /// Recover the POSIX errno from a Cocoa/POSIX error so failures normalize like the rest of the
    /// VFS layer; falls back to `EIO` when nothing more specific is available.
    private static func errnoValue(from error: Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return Int32(nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return Int32(underlying.code)
        }
        return EIO
    }
}
