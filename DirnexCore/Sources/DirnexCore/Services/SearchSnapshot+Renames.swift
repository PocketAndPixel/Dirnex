import Foundation

/// A search's hits after the app renamed some of them, or renamed a folder some of them are in
/// (2026-11-05).
///
/// A snapshot cannot re-list, so every rename the app makes is applied to it by hand. Until this
/// existed only the renamed row itself was: a hit inside a renamed folder went on showing the
/// folder's old name in its path, which addresses nothing, so opening, previewing or renaming it
/// again failed. And only the tab the rename ran in was updated, while a delete or a move had always
/// updated every results tab in the window.
///
/// **Renames apply in the order they ran, each from the path that was true when it ran.** That is
/// how every batch records them: ⇧F2 renames deepest first (``RenameOrder``), so a file inside a
/// folder is renamed while the folder still has its old name, and the folder's rename then carries
/// the file's new path along. Folding them in that order lands every hit where it really is.
extension SearchSnapshot {
    /// One rename the app carried out: an item that kept its folder and took a new name.
    public struct Renamed: Sendable, Equatable {
        /// Where the item was when the rename ran.
        public let from: VFSPath
        /// Where it is now.
        public let to: VFSPath

        public init(from: VFSPath, to: VFSPath) {
            self.from = from
            self.to = to
        }
    }

    /// Where `path` is after `renames`, applied in the order they ran: renamed itself, carried along
    /// inside a renamed folder, or where it was.
    public static func path(_ path: VFSPath, after renames: [Renamed]) -> VFSPath {
        renames.reduce(path) { current, rename in relocated(current, by: rename) ?? current }
    }

    /// `entries` with every row moved to where `renames` put it, or `nil` when none of them touches a
    /// row. Order is kept; the list re-sorts under the new names on its own.
    public static func renaming(_ entries: [FileEntry], after renames: [Renamed]) -> [FileEntry]? {
        guard !renames.isEmpty else { return nil }
        var changed = false
        let moved = entries.map { entry -> FileEntry in
            let landing = path(entry.path, after: renames)
            guard landing != entry.path else { return entry }
            changed = true
            return entry.relocated(to: landing)
        }
        return changed ? moved : nil
    }

    /// The renames an undo or a redo has just carried out, in the order it carried them out: every
    /// `.restore` step that kept its item in its own folder and did not fail.
    ///
    /// Read from the record rather than worked out again from the disk, because a rename changes
    /// nothing a `stat` could tell from any other file, and the record already says what moved
    /// where. A step the report names as failed, by either end, did not happen; and a step that
    /// crossed folders is a move, whose hit has left (``applying(_:to:)``) and is followed back by
    /// ``reconciled(_:departed:present:)`` instead.
    public static func renames(appliedBy record: UndoRecord, report: UndoReport) -> [Renamed] {
        let failed = Set(report.failures.map(\.path))
        return record.steps.compactMap { step in
            guard case let .restore(from, to) = step, isRename(from, to),
                  !failed.contains(from), !failed.contains(to)
            else { return nil }
            return Renamed(from: from, to: to)
        }
    }

    /// A move that kept its item in its own folder, on its own backend: a rename.
    static func isRename(_ source: VFSPath, _ landing: VFSPath) -> Bool {
        landing.backend == source.backend && landing.parent == source.parent
    }

    /// `path` after one rename, or `nil` when the rename does not reach it.
    static func relocated(_ path: VFSPath, by rename: Renamed) -> VFSPath? {
        guard path.backend == rename.from.backend else { return nil }
        if path == rename.from { return rename.to }
        let folder = rename.from.path.hasSuffix("/") ? rename.from.path : rename.from.path + "/"
        guard path.path.hasPrefix(folder) else { return nil }
        let inside = path.path.dropFirst(folder.count)
        let base = rename.to.path.hasSuffix("/") ? rename.to.path : rename.to.path + "/"
        return VFSPath(backend: rename.to.backend, path: base + inside)
    }
}
