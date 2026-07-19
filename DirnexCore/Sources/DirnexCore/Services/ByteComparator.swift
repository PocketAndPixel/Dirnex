import Foundation

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
