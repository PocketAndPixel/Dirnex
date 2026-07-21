import Foundation

/// What a content comparison found — the answer `prescan` gives before two files are handed to an
/// external diff tool, so the caller can skip a pointless launch or warn before an expensive one.
public enum ContentComparison: Sendable, Equatable {
    /// The two files hold identical bytes. There is nothing for a diff tool to show.
    case identical
    /// The bytes differ somewhere.
    case different
    /// At least one side is bigger than the pre-scan budget, so **nothing was read**. Settling
    /// identical-or-not would mean reading both files end to end, and a file that large is also
    /// the kind a visual diff tool struggles with — so the caller warns instead of guessing.
    /// Carries the larger of the two sizes, for the message.
    case tooLargeToScan(largestByteSize: Int64)
}

/// Byte-for-byte comparison of two on-disk files (PLAN.md §M5 "Compare by content: byte
/// compare"). This is the exact-equality primitive behind the directory-synchronizer's
/// `.content` mode and the standalone "compare files by content" command.
///
/// It touches bytes, so per §2 it lives in `DirnexCore` and is tested. The comparison is
/// chunked — it never loads a whole file into memory — and short-circuits: files of
/// different sizes are unequal without reading a byte, and reading stops at the first
/// differing chunk. The caller decides where it runs (the app drives it off the main
/// thread); pass `isCancelled` to abandon a huge comparison when the user moves on.
public enum ByteComparator {
    /// Whether the two local files hold identical bytes.
    ///
    /// - Both paths must be on the `.local` backend; anything else throws `.unsupported`
    ///   (a network read primitive arrives with `SFTPBackend`). Comparing a path with
    ///   itself is trivially `true`.
    /// - A size mismatch returns `false` immediately — no bytes are read.
    /// - Directories can't be content-compared; a non-regular file on either side throws
    ///   `.unsupported` so the caller falls back to metadata comparison.
    /// - Read failures (permission, vanished mid-read) throw `VFSError.io`.
    public static func localFilesEqual(
        _ lhs: VFSPath,
        _ rhs: VFSPath,
        chunkSize: Int = 128 * 1024,
        isCancelled: () -> Bool = { false }
    ) throws -> Bool {
        guard lhs.backend == .local, rhs.backend == .local else {
            throw VFSError.unsupported("Content comparison is only available for local files.")
        }
        guard lhs != rhs else { return true }

        let lhsSize = try regularFileSize(lhs)
        let rhsSize = try regularFileSize(rhs)
        guard lhsSize == rhsSize else { return false }
        guard lhsSize > 0 else { return true } // two empty files are equal

        let lhsHandle = try openForReading(lhs)
        defer { try? lhsHandle.close() }
        let rhsHandle = try openForReading(rhs)
        defer { try? rhsHandle.close() }

        while true {
            if isCancelled() { throw CancellationError() }
            let lhsChunk = try read(lhsHandle, upTo: chunkSize, at: lhs)
            let rhsChunk = try read(rhsHandle, upTo: chunkSize, at: rhs)
            if lhsChunk != rhsChunk { return false }
            if lhsChunk.isEmpty { return true } // both reached EOF in lock-step
        }
    }

    /// The largest file `prescan` will read through. Past this, deciding identical-or-not costs a
    /// full read of both sides — and the visual diff tool that would open next is the real problem
    /// at that size anyway, so the caller asks rather than spending the I/O to find out.
    public static let prescanByteLimit: Int64 = 64 * 1024 * 1024

    /// Look before a diff tool leaps: are these two files worth opening side by side at all?
    ///
    /// The size check comes *first* and is deliberately independent of the answer — two 2 GB files
    /// of different sizes are known-unequal for free, but that is not a reason to hand them to
    /// FileMerge. Within the budget this is exactly `localFilesEqual`, so the same short-circuits
    /// apply (a size mismatch reads no bytes; reading stops at the first differing chunk).
    ///
    /// Throws what `localFilesEqual` throws: `.unsupported` for a non-local or non-regular path,
    /// `VFSError.io` for a read failure, `CancellationError` when `isCancelled` fires.
    public static func prescan(
        _ lhs: VFSPath,
        _ rhs: VFSPath,
        byteLimit: Int64 = prescanByteLimit,
        chunkSize: Int = 128 * 1024,
        isCancelled: () -> Bool = { false }
    ) throws -> ContentComparison {
        guard lhs.backend == .local, rhs.backend == .local else {
            throw VFSError.unsupported("Content comparison is only available for local files.")
        }
        guard lhs != rhs else { return .identical }

        let lhsSize = try regularFileSize(lhs)
        let rhsSize = try regularFileSize(rhs)
        let largest = max(lhsSize, rhsSize)
        guard largest <= byteLimit else { return .tooLargeToScan(largestByteSize: largest) }

        let equal = try localFilesEqual(
            lhs,
            rhs,
            chunkSize: chunkSize,
            isCancelled: isCancelled
        )
        return equal ? .identical : .different
    }

    // MARK: - Helpers

    private static func regularFileSize(_ path: VFSPath) throws -> Int64 {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        } catch {
            throw VFSError.fromErrno(errnoValue(from: error), path: path)
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw VFSError.unsupported("Only regular files can be compared by content.")
        }
        return (attributes[.size] as? Int64) ?? 0
    }

    private static func openForReading(_ path: VFSPath) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: URL(fileURLWithPath: path.path))
        } catch {
            throw VFSError.fromErrno(errnoValue(from: error), path: path)
        }
    }

    private static func read(_ handle: FileHandle, upTo count: Int, at path: VFSPath) throws -> Data {
        do {
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw VFSError.fromErrno(errnoValue(from: error), path: path)
        }
    }

    /// Recover the POSIX errno from a Cocoa/POSIX error so failures normalize like the rest
    /// of the VFS layer; falls back to `EIO` when nothing more specific is available.
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
