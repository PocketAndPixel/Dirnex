import AppKit
import DirnexCore

/// Merge… on a Synchronize row with one side on a server (PLAN.md §M38 Slice 9).
///
/// Nothing on the server is read until the gesture: the record says the server's side moved by its
/// stamp alone, so Merge… is where its bytes come down, through the funnel every other fetch takes
/// (`materialize`), with its weighing, its progress and its Stop. The merge window then reads three
/// files on this disk, as it always has.
///
/// **Save goes the compare window's way to the server.** The result is written into the local file,
/// with its undo, and into the fetched copy, with none. The copy is then carried up through
/// `BrowserWindowController.writeBack(_:askingOver:)`, the one route an edited server file takes: it
/// checks the server's file against what was downloaded, asks when somebody wrote it since, and
/// guards the upload where the server has a tag. Once that lands the server's row is read again and
/// becomes the stamp beside the merge, now the version the pair last agreed on.
extension PanelViewController {
    /// Bring the server's file of `request` down, then read the three versions and open the window.
    /// Says why where it stops, and uploads nothing: the window's save does.
    func mergeSyncServerRow(
        _ request: SyncMergeRequest,
        server: FileEntry,
        in sheet: SyncDirectoriesController?,
        opening open: @escaping SyncMergeOpener
    ) {
        let title = BrowserWindowController.mergeFailureTitle(request.left.name)
        // Decided now, from the row the gesture saw, as an edit's destination always is.
        guard let destination = editDestination(for: server) else {
            return presentCompareFailure(
                message: title,
                detail: VFSErrorText.sentence(for: VFSError.permissionDenied(server.path))
            )
        }
        let serverDetail = compareDetail(for: server.path)
        materialize([server], for: .edit, failureMessage: { title }, then: { [weak self] urls in
            guard let self, let copy = urls.first else { return }
            let edit = EditedFile(destination: destination, temporaryURL: copy, name: server.name)
            Task {
                let read = await BlockingWork.run {
                    Self.readSyncMerge(request, serverCopy: copy, serverDetail: serverDetail)
                }
                switch read {
                case let .success(input):
                    _ = open(input, self.syncMergeSaving(request, carrying: edit, in: sheet))
                case let .failure(failure):
                    self.presentCompareFailure(
                        message: title,
                        detail: CompareOpener.failureDetail(failure)
                    )
                }
            }
        })
    }

    /// The window's saves for a row with a server side: the local file into the undo store and this
    /// pane's journal, then `edit`, the server file's copy the result was also written into, carried
    /// up by `writeBack`. Once it has landed, the server's row is read again and the merge kept with
    /// it, and the row is answered again either way.
    ///
    /// `writeBack` is the compare window's route to the server unless a test hands in its own.
    func syncMergeSaving(
        _ request: SyncMergeRequest,
        carrying edit: EditedFile,
        in sheet: SyncDirectoriesController?,
        writeBack: (@MainActor (EditedFile, NSWindow?) async -> Bool)? = nil
    ) -> MergeSaving {
        let mounts = VaultMounts.shared.mountPoints
        let backend = backend
        let writeBack = writeBack ?? compareSaving.writeBack
        return MergeSaving(
            undo: compareSaving.undo,
            journal: compareSaving.journal,
            carry: { [weak sheet] window in
                if await writeBack(edit, window), let server = request.server {
                    await BlockingWork.run(qos: .utility) {
                        guard let entry = try? backend.stat(at: server.path) else { return }
                        _ = try? request.records.store.keep(
                            relativePath: request.relativePath,
                            local: URL(fileURLWithPath: request.local.path.path),
                            server: entry,
                            for: request.records.pair,
                            vaultMountPoints: mounts
                        )
                    }
                }
                sheet?.compareAgain(rowShowing: request.left.path)
            }
        )
    }
}
