import AppKit
import DirnexCore

/// F2 with a name typed as a path (asked 2026-11-18): `Archive/2025/report.pdf` moves the item below
/// its own folder under the last name, making the folders on the way, as F7, ⇧F4 and ⌥F5 make theirs
/// (Oleg's call, over moving only into folders that are already there).
///
/// The path is read as F7's is (`NestedName`): from the item's own folder, so a leading `/`, a `.` or
/// a `..` is refused, and so is a `/` at the end. A folder cannot be moved into itself. Everything
/// else goes by F2's own three routes: the backend's move, the queued copy-then-delete a backend asks
/// for with `EXDEV` (an S3 prefix), and the archive's rewrite. One ⌘Z puts the item back and removes
/// the folders F2 made; the cursor lands on the outermost one, the row the pane shows.
///
/// ⇧F2 is unchanged: a batch name holding a `/` is still refused there, row by row.
extension PanelViewController {
    /// Move `source` to the path `typed` names below its own folder. `shownName` is the name as the
    /// row drew it, for the failure titles.
    func performPathRename(source: VFSPath, shownName: String, typed: String) {
        let failureTitle = String(
            localized: "Can’t rename “\(shownName)”",
            comment: "Rename failure title; %@ is the current name."
        )
        let name: NestedName
        do {
            name = try NestedName(parsing: typed, as: .file)
        } catch {
            if error != .empty {
                presentOperationFailure(
                    message: failureTitle,
                    detail: Self.nestedNameSentence(for: error)
                )
            }
            focusTable()
            return
        }
        let directory = source.parent ?? panel.path
        let target = name.target(in: directory)
        guard target != source, !target.isSelfOrDescendant(of: source) else {
            presentOperationFailure(
                message: failureTitle,
                detail: String(
                    localized: "“\(shownName)” can’t be moved into itself.",
                    comment: "Rename failure detail: a folder renamed to a path inside itself; %@ is its name."
                )
            )
            focusTable()
            return
        }
        let landing = name.outermost(in: directory)
        switch renameRoute(for: source) {
        case let .archiveMember(archiveOnDiskPath):
            moveArchiveMember(
                source, to: name, landing: landing, title: failureTitle,
                inArchiveAt: archiveOnDiskPath
            )
        case .unavailable:
            focusTable()
        case .backend:
            moveByBackend(source, to: target, landing: landing, title: failureTitle)
        }
    }

    /// The backend's move, with the folders on the way made first and taken back if it fails.
    private func moveByBackend(
        _ source: VFSPath,
        to target: VFSPath,
        landing: VFSPath,
        title: String
    ) {
        // The entry as the pane knows it, for the job a backend that cannot move in place asks for.
        let sourceEntry = panel.displayedIndex(ofID: source).flatMap { panel.displayedEntry(at: $0) }
        let backend = backend
        Task {
            do {
                let moved = try await BlockingWork.run {
                    Result { try NestedCreation.move(source, to: target, using: backend) }
                }.get()
                guard !moved.deferred else {
                    deferPathRename(sourceEntry, to: target, made: moved.folders, title: title)
                    return
                }
                noteSearchHitsRenamed(
                    [SearchSnapshot.Renamed(from: source, to: target)],
                    landing: target
                )
                refreshCurrentDirectory(selecting: landing)
                focusTable()
                host?.recordUndoableAction(
                    .rename(from: source, to: target, madeFolders: moved.folders)
                )
            } catch {
                presentOperationFailure(
                    message: title,
                    detail: describeCreateFailure(error, making: target)
                )
                focusTable()
            }
        }
    }

    /// `EXDEV`: the backend moves this only the long way, so it goes to the queue as a rename job
    /// into the new folder, after the same confirmation a plain rename of it gets. The folders are
    /// journaled as a New Folder of their own, as Export's are, since the job's undo is its own.
    private func deferPathRename(
        _ entry: FileEntry?,
        to target: VFSPath,
        made: [VFSPath],
        title: String
    ) {
        if let record = UndoRecord.newFolders(made) { host?.recordUndoableAction(record) }
        guard let entry, let directory = target.parent else {
            presentOperationFailure(message: title, detail: describe(VFSError.notFound(target)))
            focusTable()
            return
        }
        refreshCurrentDirectory()
        queueDeferredRenames([
            DeferredRename(source: entry, newName: target.lastComponent, directory: directory)
        ])
    }

    /// The archive's route: one rewrite that makes the folders on the way and moves the member, which
    /// ⌘Z undoes as a whole by putting the container back.
    private func moveArchiveMember(
        _ source: VFSPath,
        to name: NestedName,
        landing: VFSPath,
        title: String,
        inArchiveAt archiveOnDiskPath: String
    ) {
        let innerPath = source.path
        guard let destination = ArchiveMutation.movedInnerPath(ofInnerPath: innerPath, to: name) else {
            focusTable()
            return
        }
        let target = VFSPath(backend: source.backend, path: destination)
        let encoding = declaredNameEncoding(forArchiveAt: archiveOnDiskPath)
        withArchivePassphrase(forArchiveAt: archiveOnDiskPath) { passphrase in
            try await BlockingWork.run {
                Result {
                    try ArchiveWriter.move(
                        innerPath: innerPath,
                        to: destination,
                        inArchiveAt: archiveOnDiskPath,
                        passphrase: passphrase,
                        undo: ArchiveUndoStorage.request(),
                        nameEncoding: encoding
                    )
                }
            }.get()
        } onSuccess: { [weak self] snapshot in
            guard let self else { return }
            (backend as? CompositeBackend)?.invalidateMountedArchive(at: archiveOnDiskPath)
            let renamed = [PathRename(from: source, to: target)]
            journalArchiveRewrite(snapshot, renamed: renamed)
            noteSearchHitsRenamed(renamed, landing: target)
            refreshArchiveDirectory { [weak self] in self?.moveCursor(onto: landing) }
            focusTable()
        } onFailure: { [weak self] error in
            guard let self else { return }
            guard !offerNameEncoding(after: error, forArchiveAt: archiveOnDiskPath) else {
                focusTable()
                return
            }
            presentOperationFailure(
                message: title,
                detail: describeCreateFailure(error, making: target)
            )
            focusTable()
        }
    }
}
