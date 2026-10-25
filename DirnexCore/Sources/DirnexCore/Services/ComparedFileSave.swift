import Foundation

/// Saving one side of a comparison to the local file it was read from (PLAN.md §M33 Slice 3).
///
/// Four things happen, in an order that never leaves the file worse off than it was:
///
/// 1. The lines are encoded first, so a character the encoding cannot hold is refused by name
///    before anything is touched.
/// 2. The file's size and modification time are compared with what was read, and a file that has
///    moved on is refused unless the user has said to save anyway. The check reads the file a
///    symlink points at, which is the file a save writes.
/// 3. The undo store takes a copy of the file's current bytes, the way an archive rewrite's are
///    taken (``ArchiveUndoStore/capture(archiveAt:live:)``).
/// 4. The new bytes are written into the file in place (`InPlaceFileWrite`), which keeps the file
///    and everything stored on it. A write that fails partway is undone by writing the old bytes
///    back the same way, with their modification time, and the store's copy is dropped.
public enum ComparedFileSave {
    /// Why a save did not happen.
    public enum Failure: Error, Equatable {
        /// `character`, on line `line` (counted from 0), has no bytes in the file's encoding.
        case unencodable(line: Int, character: Character)
        /// The file's size or modification time is not what was read. Nothing was written; the
        /// window asks whether to save anyway.
        case changedSinceRead
        /// The file could not be written, and was left with the bytes it had.
        case failed(VFSError)
    }

    /// The local file a side saves to, and what it looked like when it was read or last saved:
    /// the witness the next save is checked against.
    public struct Target: Sendable, Equatable {
        public let path: String
        public let witness: ArchiveUndoWitness?

        public init(path: String, witness: ArchiveUndoWitness?) {
            self.path = path
            self.witness = witness
        }

        /// The file at `path` as it is now. Taken just before the file is read, so a write that
        /// lands during the read makes the next save ask rather than overwrite it.
        public static func reading(_ path: String) -> Target {
            Target(path: path, witness: ArchiveUndoWitness.current(ofFileAt: path))
        }
    }

    /// Where a save keeps the bytes it replaces, so ⌘Z can put them back: the store, and every
    /// snapshot the journal still names, which its budget may not evict.
    public struct UndoCopy: Sendable {
        public let store: ArchiveUndoStore
        public let live: [String]

        public init(store: ArchiveUndoStore, live: [String]) {
            self.store = store
            self.live = live
        }
    }

    /// A save that landed.
    public struct Saved: Sendable, Equatable {
        /// The file as it now stands, which the next save is checked against.
        public let target: Target
        /// The journal record whose ⌘Z puts the old bytes back, or `nil` when there is no undo
        /// store or its copy could not be made.
        public let undo: UndoRecord?
    }

    /// Save `document` to `target`.
    ///
    /// `overwritingChanges` skips the check that the file is still as it was read: the user's
    /// answer when the window asked. Blocking; call it off the main thread.
    public static func save(
        _ document: ComparedDocument,
        to target: Target,
        overwritingChanges: Bool = false,
        undo: UndoCopy?
    ) throws(Failure) -> Saved {
        try save(
            document,
            to: target,
            overwritingChanges: overwritingChanges,
            undo: undo,
            writer: InPlaceFileWrite.writeAll
        )
    }

    /// `save`, with the writer a test can make fail partway.
    static func save(
        _ document: ComparedDocument,
        to target: Target,
        overwritingChanges: Bool,
        undo: UndoCopy?,
        writer: InPlaceFileWrite.Writer
    ) throws(Failure) -> Saved {
        let file = VFSPath.local(target.path)
        let data: Data
        do {
            data = try document.encoded()
        } catch {
            switch error {
            case let .unencodable(line, character):
                throw .unencodable(line: line, character: character)
            }
        }
        guard let resolved = resolvedPath(target.path),
              let current = ArchiveUndoWitness.current(ofFileAt: resolved)
        else { throw .failed(.notFound(file)) }
        guard overwritingChanges || current == target.witness else { throw .changedSinceRead }
        guard let previous = FileManager.default.contents(atPath: resolved) else {
            throw .failed(.permissionDenied(file))
        }
        let previousTime = InPlaceFileWrite.modificationTime(ofFileAt: resolved)

        let snapshot = undo?.store.capture(archiveAt: resolved, live: undo?.live ?? [])
        do {
            try InPlaceFileWrite.replaceContents(ofFileAt: resolved, with: data, writer: writer)
        } catch {
            if error.touchedTheFile {
                try? InPlaceFileWrite.replaceContents(
                    ofFileAt: resolved,
                    with: previous,
                    modified: previousTime
                )
            }
            snapshot.map { undo?.store.discard($0.snapshot) }
            throw .failed(VFSError.fromErrno(error.code, path: file))
        }
        guard let saved = ArchiveUndoWitness.current(ofFileAt: resolved) else {
            throw .failed(.notFound(file))
        }
        return Saved(
            target: Target(path: target.path, witness: saved),
            undo: snapshot?.savedFileRecord()
        )
    }

    /// The file `path` names with every symlink resolved: the one a save writes into, and the one
    /// its undo record names, since the undo's swap must land on the same file. `nil` when there is
    /// none.
    static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
