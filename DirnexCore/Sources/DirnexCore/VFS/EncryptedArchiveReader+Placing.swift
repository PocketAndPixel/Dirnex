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
        let reporting: Reporting
    }

    /// What placing one entry left behind, beyond the bytes it wrote.
    struct Placement {
        /// The running byte total, so the progress denominator keeps its meaning across entries.
        let bytesWritten: Int64
        /// A directory that was created and still needs its modification time — see
        /// ``EncryptedArchiveReader/place(_:at:alreadyWritten:in:)`` for why it cannot be stamped
        /// where it is made.
        let directoryNeedingTime: String?
    }

    static func place(
        _ entry: Entry,
        at relativePath: String,
        alreadyWritten: Int64,
        in session: Session
    ) throws -> Placement {
        let root = session.root
        var components = relativePath.split(separator: "/").map(String.init)
        let leaf = components.removeLast()
        let parent = try extractionDirectory(under: root, components: components)
        let destination = (parent as NSString).appendingPathComponent(leaf)

        switch entry.kind {
        case .directory:
            try makeDirectory(at: destination)
            // Handed back rather than stamped here, and that is measured rather than cautious:
            // creating an entry inside a directory moves that directory's own mtime, so a time
            // applied now is undone by the very next file placed in it. Stamping a *child* leaves
            // its parent alone, which is why the caller's deferred pass needs no ordering.
            return Placement(bytesWritten: alreadyWritten, directoryNeedingTime: destination)

        case let .symbolicLink(target):
            guard ArchiveEntryPath.isSafeSymlinkTarget(target, forLinkAt: relativePath) else {
                // Not reported as a refusal: the entry's *name* was fine, so this is a different
                // failure — an archive trying to plant a way out of the destination. Dropping it is
                // the whole mitigation; nothing else in the archive needs to be abandoned for it.
                return Placement(bytesWritten: alreadyWritten, directoryNeedingTime: nil)
            }
            try? FileManager.default.removeItem(atPath: destination)
            guard symlink(target, destination) == 0 else {
                throw VFSError.fromErrno(errno, path: .local(destination))
            }
            applyModificationTime(entry.modificationDate, toItemAt: destination)
            return Placement(bytesWritten: alreadyWritten, directoryNeedingTime: nil)

        case .regularFile:
            let written = try writeFile(
                entry, to: destination, alreadyWritten: alreadyWritten, in: session
            )
            return Placement(bytesWritten: written, directoryNeedingTime: nil)
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
            if session.reporting.isCancelled() { throw CancellationError() }
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
            session.reporting.onProgress(Progress(
                bytesExtracted: written, totalBytes: session.totalBytes,
                currentName: entry.archivePath
            ))
        }
        // Through the descriptor that is still open rather than by path: nothing can have been
        // swapped underneath it, which is the same reasoning as the `O_NOFOLLOW` above.
        applyModificationTime(entry.modificationDate, to: descriptor)
        return written
    }

    // MARK: - Modification times

    /// Give the file behind `descriptor` the modification time the archive recorded for it.
    ///
    /// Without this the staged tree carries the moment it was extracted — and because an archive
    /// rewrite is extract → edit → repack, renaming one member restamped **every** entry in the
    /// container with the time of the rewrite (found 2026-09-10 while verifying a rename inside a
    /// declared archive: two members went from `09.09.2026 23:40` to `10.09.2026 16:55`, including
    /// the one nothing had touched). `bsdtar -x`, the engine the *other* rewrite route uses,
    /// restores times by default — measured, a 2024 stamp comes back to the second — so this is
    /// what keeps the two routes answering the same thing rather than a behaviour of its own.
    ///
    /// Only the modification time is written. `UTIME_OMIT` leaves the access time alone, which is
    /// the field no format here round-trips and the one a repack has no business inventing.
    ///
    /// A failure is deliberately ignored: the name and the bytes are already correct by this point,
    /// and a filesystem that will not take a timestamp is not a reason to abandon an extraction.
    static func applyModificationTime(_ date: Date, to descriptor: Int32) {
        var times = modificationTimes(date)
        _ = futimens(descriptor, &times)
    }

    /// The same for an item with no open descriptor — a **symlink**, whose own time is wanted and
    /// never its target's, and a directory being stamped after the walk. `AT_SYMLINK_NOFOLLOW` is
    /// what makes the first of those true.
    static func applyModificationTime(_ date: Date, toItemAt path: String) {
        var times = modificationTimes(date)
        _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
    }

    /// `(access, modification)` for `utimensat`, with the access half omitted.
    ///
    /// The seconds are **clamped**, because this converts back a value the archive supplied and an
    /// archive is hostile input (see the type doc): `time_t(aDouble)` traps outside its range, and
    /// a crafted header can name a year no `Double` round-trips into one. The bound is far past any
    /// real date, so nothing legitimate is altered by it.
    ///
    /// The precision is the second, since ``EncryptedArchiveReader/Entry/modificationDate`` is built
    /// from `archive_entry_mtime`. A zip stores no more than that; a pax tar can, and its
    /// sub-second part is therefore lost across a rewrite.
    private static func modificationTimes(_ date: Date) -> [timespec] {
        let limit = 4e18
        let raw = date.timeIntervalSince1970
        let bounded = raw.isFinite ? max(-limit, min(limit, raw)) : 0
        return [
            timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)),
            timespec(tv_sec: time_t(bounded), tv_nsec: 0)
        ]
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
