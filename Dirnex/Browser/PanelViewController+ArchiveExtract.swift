import AppKit
import DirnexCore

/// F5 copy-out from inside a browsed archive (PLAN.md §M4 "copy out with F5").
///
/// `CopyEngine` takes one backend for both source and destination, so an archive→local copy
/// can't go straight through it. Instead the marked members are extracted to a temp directory
/// with `bsdtar` (`ArchiveExtractor`) and the resulting *real* files are handed to the normal
/// copy queue via `submitTransfer` — reusing every bit of its conflict / progress / undo
/// machinery, landing in the other pane exactly like a local copy. Copy only: a read-only
/// archive has no source to remove, so there is no move-out.
extension PanelViewController {
    /// Extract the marked/cursor members of this archive pane to disk, then copy them into the
    /// other pane's directory. Runs the extraction off-main and, for whatever landed, stats the
    /// files back into local `FileEntry` sources the copy queue understands.
    func beginArchiveExtraction() {
        guard let archivePath = panel.path.backend.archivePath else { return }
        let sources = selectionTargets()
        guard !sources.isEmpty, let destPane = host?.panelCounterpart(of: self) else { return }

        let destination = destPane.panel.path
        // The other pane must be a real, writable on-disk folder to receive the extracted files.
        guard destination.backend == .local, destPane.backend.capabilities.contains(.write) else {
            presentOperationFailure(
                message: "Can’t extract here",
                detail: "Open a folder on disk in the other panel first."
            )
            return
        }

        let innerPaths = sources.map(\.path.path)
        let backend = backend
        Task {
            do {
                let localSources = try await Task.detached(priority: .userInitiated) {
                    () throws -> [FileEntry] in
                    let extraction = try ArchiveExtractor.extract(
                        innerPaths: innerPaths,
                        fromArchiveAt: archivePath
                    )
                    // Stat each extracted file into a local source entry; a member bsdtar couldn't
                    // find never landed, so its stat fails and it's dropped from the copy.
                    return extraction.extractedPaths.compactMap { try? backend.stat(at: .local($0)) }
                }.value

                guard !localSources.isEmpty else {
                    presentOperationFailure(
                        message: "Couldn’t extract the selected items",
                        detail: "The archive may be damaged or the items may be missing."
                    )
                    return
                }
                submitTransfer(kind: .copy, sources: localSources, destination: destination)
                // Marks are consumed the moment the copy is queued, matching F5/delete; the
                // window re-lists both panes as the job finishes.
                panel.clearSelection()
                reloadEverything()
                focusTable()
            } catch {
                presentOperationFailure(
                    message: "Couldn’t extract from the archive",
                    detail: describe(error)
                )
            }
        }
    }
}
