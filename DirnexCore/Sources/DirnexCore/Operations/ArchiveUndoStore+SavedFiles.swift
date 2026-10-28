import Foundation

/// The undo store widened from archives to a text file saved from the compare window (PLAN.md §M33
/// Slice 3).
///
/// A save is captured exactly as a rewrite is, by ``ArchiveUndoStore/capture(archiveAt:live:)``
/// with the file's resolved path, and the same budget, prune and witness hold it. Only the way back
/// differs: the save wrote in place to keep the file's inode (`InPlaceFileWrite`), so ⌘Z does too.
extension ArchiveUndoStore {
    /// Give the file at `path` the snapshot's bytes and the snapshot the file's, writing the file
    /// in place.
    ///
    /// The same four steps as ``exchange(archiveAt:snapshotAt:)``, with the rename over the file
    /// replaced by a write into it:
    ///
    /// 1. Read the snapshot's bytes and modification time.
    /// 2. Copy the file's current bytes into the store beside the snapshot, so they survive step 3
    ///    and become what a Redo writes back.
    /// 3. Write the snapshot's bytes into the file, and give it the snapshot's modification time,
    ///    which is the time the file had before the change being undone. That is what makes the
    ///    witness the record stored at the time true of the file afterwards.
    /// 4. `rename(2)` the kept copy over the snapshot.
    ///
    /// A failure before step 3 leaves everything as it was. A write that fails partway is undone by
    /// writing the kept copy back; should that fail as well, the kept copy is left in the store
    /// rather than deleted, since it is then the only copy of those bytes.
    public static func exchangeInPlace(fileAt path: String, snapshotAt snapshotPath: String) throws {
        try exchangeInPlace(
            fileAt: path,
            snapshotAt: snapshotPath,
            writer: InPlaceFileWrite.writeAll
        )
    }

    /// `exchangeInPlace`, with the writer a test can make fail partway.
    static func exchangeInPlace(
        fileAt path: String,
        snapshotAt snapshotPath: String,
        writer: InPlaceFileWrite.Writer
    ) throws {
        let file = VFSPath.local(path)
        let kept = snapshotPath + ".incoming"
        guard let incoming = FileManager.default.contents(atPath: snapshotPath),
              let incomingTime = InPlaceFileWrite.modificationTime(ofFileAt: snapshotPath)
        else {
            throw VFSError.unsupported(.archiveUndoCopyUnavailable(archive: file.lastComponent))
        }
        guard duplicate(from: path, to: kept) else { throw VFSError.io(path: file, code: EIO) }
        do {
            try InPlaceFileWrite.replaceContents(
                ofFileAt: path,
                with: incoming,
                modified: incomingTime,
                writer: writer
            )
        } catch {
            if !error.touchedTheFile || putBack(kept, into: path) {
                try? FileManager.default.removeItem(atPath: kept)
            }
            throw VFSError.fromErrno(error.code, path: file)
        }
        // Past here the file is already back; a failure now costs the *redo*, as it does for an
        // archive, so it is reported rather than rolled back.
        guard rename(kept, snapshotPath) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(atPath: kept)
            throw VFSError.io(path: file, code: code)
        }
    }

    /// Write the bytes kept at `kept` back into the file at `path`, with their modification time.
    /// `true` when that worked.
    static func putBack(_ kept: String, into path: String) -> Bool {
        guard let bytes = FileManager.default.contents(atPath: kept) else { return false }
        do {
            try InPlaceFileWrite.replaceContents(
                ofFileAt: path,
                with: bytes,
                modified: InPlaceFileWrite.modificationTime(ofFileAt: kept)
            )
            return true
        } catch {
            return false
        }
    }
}

public extension ArchiveUndoSnapshot {
    /// The journal record for a finished save, read off the file as it now stands: the saved-file
    /// twin of ``record(date:)``. `nil` when the file cannot be read, which leaves the save
    /// unjournalled rather than journalled with a guard nothing can satisfy.
    func savedFileRecord(date: Date = Date()) -> UndoRecord? {
        guard let current = ArchiveUndoWitness.current(ofFileAt: archive) else { return nil }
        return UndoRecord(
            label: .saveFile,
            date: date,
            steps: [.restoreSavedFile(
                file: .local(archive),
                snapshot: .local(snapshot),
                expected: current,
                restored: restored
            )]
        )
    }
}
