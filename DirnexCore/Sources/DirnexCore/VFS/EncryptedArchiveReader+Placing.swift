import CArchiveShim
import Foundation

/// Where an extracted entry actually lands on disk — the second half of the traversal defense.
///
/// Split from `EncryptedArchiveReader` by concept rather than to shave lines: that type reads the
/// archive, and this one writes the filesystem, which is where every rule about *not* writing
/// outside the destination belongs. `ArchiveEntryPath` holds the pure half of the same subject.
extension EncryptedArchiveReader {
    /// What stays constant for a whole extraction — the open handle, the destination, the total the
    /// progress values are measured against, and the two callbacks. Bundled so placing an entry
    /// takes one value rather than six unchanging arguments.
    struct Session {
        let handle: ArchiveReadHandle
        let root: String
        let totalBytes: Int64
        let onProgress: (Progress) -> Void
        let isCancelled: () -> Bool
    }

    static func place(
        _ entry: Entry,
        at relativePath: String,
        alreadyWritten: Int64,
        in session: Session
    ) throws -> Int64 {
        let root = session.root
        var components = relativePath.split(separator: "/").map(String.init)
        let leaf = components.removeLast()
        let parent = try extractionDirectory(under: root, components: components)
        let destination = (parent as NSString).appendingPathComponent(leaf)

        switch entry.kind {
        case .directory:
            try makeDirectory(at: destination)
            return alreadyWritten

        case let .symbolicLink(target):
            guard ArchiveEntryPath.isSafeSymlinkTarget(target, forLinkAt: relativePath) else {
                // Not reported as a refusal: the entry's *name* was fine, so this is a different
                // failure — an archive trying to plant a way out of the destination. Dropping it is
                // the whole mitigation; nothing else in the archive needs to be abandoned for it.
                return alreadyWritten
            }
            try? FileManager.default.removeItem(atPath: destination)
            guard symlink(target, destination) == 0 else {
                throw VFSError.fromErrno(errno, path: .local(destination))
            }
            return alreadyWritten

        case .regularFile:
            return try writeFile(entry, to: destination, alreadyWritten: alreadyWritten, in: session)
        }
    }

    static func writeFile(
        _ entry: Entry,
        to destination: String,
        alreadyWritten: Int64,
        in session: Session
    ) throws -> Int64 {
        let handle = session.handle
        // `O_NOFOLLOW` is the last line of the traversal defense: if `destination` already exists as
        // a symlink — planted by an earlier entry of this very archive, or sitting in the
        // destination beforehand — this refuses rather than writing through it. `unlink` first so a
        // re-extract overwrites a real file normally.
        try? FileManager.default.removeItem(atPath: destination)
        let descriptor = open(
            destination,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            entry.permissions
        )
        guard descriptor >= 0 else {
            throw VFSError.fromErrno(errno, path: .local(destination))
        }
        defer { close(descriptor) }

        var written = alreadyWritten
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            if session.isCancelled() { throw CancellationError() }
            let got = buffer.withUnsafeMutableBytes {
                archive_read_data(handle.raw, $0.baseAddress, chunkSize)
            }
            if got == 0 { break }
            guard got > 0 else { throw failure(handle) }

            var offset = 0
            while offset < got {
                let put = buffer.withUnsafeBytes {
                    write(descriptor, $0.baseAddress!.advanced(by: offset), got - offset)
                }
                guard put > 0 else { throw VFSError.fromErrno(errno, path: .local(destination)) }
                offset += put
            }
            written += Int64(got)
            session.onProgress(Progress(
                bytesExtracted: written, totalBytes: session.totalBytes,
                currentName: entry.archivePath
            ))
        }
        return written
    }

    // MARK: - Safe directory walk

    /// Resolves (creating as needed) the directory `components` name under `root`, refusing to walk
    /// through a symlink at any level.
    ///
    /// This is the half of the traversal defense that ``ArchiveEntryPath/sanitized(_:)`` cannot
    /// provide. A clean entry name still lands in the wrong place if one of the directories on the
    /// way to it is a link — and an archive can create exactly that, because it may contain both
    /// `docs -> /tmp` and `docs/notes.txt`, each of which passes a name check on its own.
    /// `lstat`-ing each component and refusing a symlink is the path-shaped equivalent of walking
    /// with `openat(O_NOFOLLOW)`.
    static func extractionDirectory(under root: String, components: [String]) throws -> String {
        var current = root
        try makeDirectory(at: current)
        for component in components {
            current = (current as NSString).appendingPathComponent(component)
            var status = stat()
            if lstat(current, &status) == 0 {
                guard (status.st_mode & S_IFMT) == S_IFDIR else {
                    // Exists and is not a real directory — a symlink, or a file of the same name.
                    throw VFSError.fromErrno(EEXIST, path: .local(current))
                }
            } else {
                try makeDirectory(at: current)
            }
        }
        return current
    }

    static func makeDirectory(at path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true
            )
        } catch {
            var status = stat()
            if lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR { return }
            throw VFSError.fromErrno(errno, path: .local(path))
        }
    }
}
