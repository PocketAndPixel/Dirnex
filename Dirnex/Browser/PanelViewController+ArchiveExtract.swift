import AppKit
import DirnexCore

/// F5 copy-out from inside a browsed archive (PLAN.md §M4 "copy out with F5").
///
/// `CopyEngine` takes one backend for both source and destination, so an archive→local copy
/// can't go straight through it. Instead the marked members are extracted to a temp directory
/// (`ArchiveExtractor`) and the resulting *real* files are handed to the normal copy queue via
/// `submitTransfer` — reusing every bit of its conflict / progress / undo machinery, landing in
/// the other pane exactly like a local copy. Copy only: a read-only archive has no source to
/// remove, so there is no move-out.
///
/// An **encrypted** archive is asked for its passphrase first (PLAN.md §M19). The names in a zip's
/// central directory are never encrypted, so such an archive browses normally and the passphrase is
/// wanted only at the moment bytes are — which is also the only moment the user has any context for
/// the question.
extension PanelViewController {
    /// The on-disk archive `sources` have to be extracted from, or `nil` when they are not archive
    /// members at all.
    ///
    /// Two panes can hold them, and only one of them *is* an archive. The pane's own path answers
    /// for the browse case; a **results tab** does not, because its container is the synthetic
    /// `search:` path while every row carries its real `archive:` one — which is the shape M22 made
    /// reachable by letting ⌥F7 walk an archive. Without this the hits looked ordinary and F5 on one
    /// failed inside the queue with "This location doesn't support copying files", the archive
    /// backend having no `copyFile` (found live, 2026-08-16).
    ///
    /// Every source must come from the *same* archive, which a single search always satisfies and a
    /// hand-assembled selection need not; extracting from two archives is a second job, not a
    /// second path through this one.
    func extractionArchivePath(for sources: [FileEntry]) -> String? {
        if let own = panel.path.backend.archivePath { return own }
        guard let backend = sources.first?.path.backend, backend.isArchive,
              sources.allSatisfy({ $0.path.backend == backend })
        else { return nil }
        return backend.archivePath
    }

    /// Extract the marked/cursor members of this archive pane to disk, then copy them into the
    /// other pane's directory. Runs the extraction off-main and, for whatever landed, stats the
    /// files back into local `FileEntry` sources the copy queue understands.
    func beginArchiveExtraction() {
        let sources = selectionTargets()
        guard let archivePath = extractionArchivePath(for: sources) else { return }
        guard !sources.isEmpty, let destPane = host?.panelCounterpart(of: self) else { return }

        let destination = destPane.panel.path
        // The other pane must be a real, writable on-disk folder to receive the extracted files.
        guard destination.backend == .local, destPane.backend.capabilities.contains(.write) else {
            presentOperationFailure(
                message: String(localized: "Can’t extract here"),
                detail: String(localized: "Open a folder on disk in the other panel first.")
            )
            return
        }

        // The encryption question, the prompt and its retry all live in `withArchivePassphrase`,
        // shared with preview, member-open and nested-archive entry — so an archive unlocked by any
        // of them is not asked about again.
        let innerPaths = sources.map(\.path.path)
        let backend = backend
        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            try await BlockingWork.run { () -> Result<[FileEntry], any Error> in
                Result {
                    let extraction = try ArchiveExtractor.extract(
                        innerPaths: innerPaths,
                        fromArchiveAt: archivePath,
                        passphrase: passphrase
                    )
                    // Stat each extracted file into a local source entry; a member that never
                    // landed — bsdtar couldn't find it, or the reader refused its name as a
                    // traversal attempt — fails its stat and is dropped from the copy.
                    return extraction.extractedPaths.compactMap {
                        try? backend.stat(at: .local($0))
                    }
                }
            }.get()
        } onSuccess: { [weak self] localSources in
            self?.finishArchiveExtraction(localSources: localSources, destination: destination)
        } onFailure: { [weak self] error in
            self?.presentOperationFailure(
                message: String(localized: "Couldn’t extract from the archive"),
                detail: self?.describe(error) ?? ""
            )
        }
    }

    /// Hand what landed on disk to the normal copy queue, or say that nothing did.
    private func finishArchiveExtraction(localSources: [FileEntry], destination: VFSPath) {
        guard !localSources.isEmpty else {
            presentOperationFailure(
                message: String(localized: "Couldn’t extract the selected items"),
                detail: String(
                    localized: "The archive may be damaged or the items may be missing."
                )
            )
            return
        }
        submitTransfer(kind: .copy, sources: localSources, destination: destination)
        // Marks are consumed the moment the copy is queued, matching F5/delete; the window re-lists
        // both panes as the job finishes.
        panel.clearSelection()
        reloadEverything()
        focusTable()
    }
}
