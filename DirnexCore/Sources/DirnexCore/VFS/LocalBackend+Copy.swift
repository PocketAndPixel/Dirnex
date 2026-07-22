import Foundation

/// `LocalBackend`'s byte-copy primitives — the operation engine's fast paths (PLAN.md §2
/// "COPYFILE_CLONE fast path"): the APFS clone, the chunked file copy behind it, symlink
/// re-creation, metadata carry-over, and the volume grouping the queue serializes on.
///
/// Split out of `LocalBackend.swift` purely for length: the struct rides SwiftLint's
/// `type_body_length` 250 (docs/NOTES.md), and this MARK section was already the file's own seam.
/// Nothing moved changed.
public extension LocalBackend {
    func cloneItem(at source: VFSPath, to destination: VFSPath) throws -> Bool {
        let cSource = (source.path as NSString).fileSystemRepresentation
        let cDest = (destination.path as NSString).fileSystemRepresentation
        // clonefile(2) copies a whole hierarchy as a copy-on-write clone, preserving
        // metadata — instant on APFS. It clones a symlink as a symlink rather than
        // following it, so nested links survive faithfully.
        guard clonefile(cSource, cDest, 0) != 0 else { return true }
        switch errno {
        case ENOTSUP, EXDEV:
            // Different volume, or a filesystem without copy-on-write: not an error —
            // the engine falls back to a chunked recursive copy.
            return false
        default:
            throw VFSError.fromErrno(errno, path: destination)
        }
    }

    func copyFile(
        at source: VFSPath,
        to destination: VFSPath,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let readFD = open((source.path as NSString).fileSystemRepresentation, O_RDONLY)
        guard readFD >= 0 else { throw VFSError.fromErrno(errno, path: source) }
        defer { close(readFD) }

        let cDest = (destination.path as NSString).fileSystemRepresentation
        // O_EXCL so a destination that reappeared under us is reported, never clobbered —
        // the engine has already applied the conflict policy before calling in.
        let writeFD = open(cDest, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard writeFD >= 0 else { throw VFSError.fromErrno(errno, path: destination) }

        do {
            try streamBytes(from: readFD, to: writeFD, progress: progress, isCancelled: isCancelled)
        } catch {
            close(writeFD)
            unlink(cDest) // don't leave a half-written file behind on cancel/error
            throw error
        }
        close(writeFD)

        // Carry over permissions, timestamps, and extended attributes (Finder tags live
        // there). Failing to copy metadata shouldn't fail the copy — the bytes are safe.
        copyfile(
            (source.path as NSString).fileSystemRepresentation,
            cDest,
            nil,
            copyfile_flags_t(COPYFILE_METADATA)
        )
    }

    func createSymbolicLink(at destination: VFSPath, withDestination target: String) throws {
        let cTarget = (target as NSString).fileSystemRepresentation
        let cDest = (destination.path as NSString).fileSystemRepresentation
        guard symlink(cTarget, cDest) == 0 else {
            throw VFSError.fromErrno(errno, path: destination)
        }
    }

    func copyMetadata(at source: VFSPath, to destination: VFSPath) throws {
        let cSource = (source.path as NSString).fileSystemRepresentation
        let cDest = (destination.path as NSString).fileSystemRepresentation
        copyfile(cSource, cDest, nil, copyfile_flags_t(COPYFILE_METADATA))
    }

    func volumeIdentifier(for path: VFSPath) -> String? {
        // `st_dev` is the mounted-filesystem id: equal within a volume, distinct across
        // mounts — exactly the grouping the operation queue needs. We follow symlinks
        // (flags 0) so the id reflects where the bytes actually live, and walk up to the
        // nearest existing ancestor so a destination that hasn't been created yet still
        // resolves to the volume it will land on.
        var probe: VFSPath? = path
        while let candidate = probe {
            var info = Darwin.stat()
            if fstatat(AT_FDCWD, (candidate.path as NSString).fileSystemRepresentation, &info, 0) == 0 {
                return String(info.st_dev)
            }
            probe = candidate.parent
        }
        return nil
    }

    /// The chunked read→write loop behind `copyFile`. A 1 MiB buffer balances syscall
    /// overhead against memory; cancellation is checked once per chunk so even a huge
    /// file abandons promptly.
    ///
    /// Internal rather than private only because it lives in an extension: Swift's `private`
    /// does not cross files (docs/NOTES.md).
    internal func streamBytes(
        from readFD: Int32,
        to writeFD: Int32,
        progress: (Int64) -> Void,
        isCancelled: () -> Bool
    ) throws {
        let chunkSize = 1 << 20
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            if isCancelled() { throw CancellationError() }
            let bytesRead = buffer.withUnsafeMutableBytes { read(readFD, $0.baseAddress, chunkSize) }
            if bytesRead == 0 { break } // EOF
            guard bytesRead > 0 else { throw VFSError.io(path: .local("/"), code: errno) }

            var offset = 0
            while offset < bytesRead {
                let written = buffer.withUnsafeBytes {
                    write(writeFD, $0.baseAddress!.advanced(by: offset), bytesRead - offset)
                }
                guard written > 0 else { throw VFSError.io(path: .local("/"), code: errno) }
                offset += written
            }
            progress(Int64(bytesRead))
        }
    }
}
