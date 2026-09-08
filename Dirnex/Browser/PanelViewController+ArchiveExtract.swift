import AppKit
import DirnexCore

/// Getting bytes **out** of a browsed archive: F5 copy-out (PLAN.md §M4 "copy out with F5"), and
/// since M23 Slice 5 the ⌘V and drop that reach the same rows.
///
/// `CopyEngine` takes one backend for both source and destination, so an archive→local copy
/// can't go straight through it. Instead the marked members are extracted to a temp directory
/// (`ArchiveExtractor`) and the resulting *real* files are handed to the normal copy queue via
/// `submitTransfer` — reusing every bit of its conflict / progress / undo machinery, landing in
/// the other pane exactly like a local copy. Copy only: a read-only archive has no source to
/// remove, so there is no move-out (`TransferAdmission.allowsMove`).
///
/// `extractArchiveSources` is that step on its own, because F5 is no longer its only caller. It was
/// welded into `beginArchiveExtraction`, which reads *this* pane's selection and the *counterpart*
/// pane's path — neither of which a paste has — so a paste written against it would have grown a
/// second spelling of the extraction, which is this project's most repeated bug. It is the same
/// split `editRoute(for:)` records making for F4 and ⇧F4.
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
    /// hand-assembled selection need not; F5 extracting from two archives is a second job, not a
    /// second path through this one. (⌘V and a drop *do* take several, because they resolve their
    /// sources through `ArchiveTransferSources` and run one extraction per group — the difference is
    /// that F5's destination and marks come from the panes, so there is one of everything.)
    ///
    /// Expressed on the same split the paste and drop routes read, rather than a second scan of its
    /// own: "which of these rows are archive members, and whose" is one question, and this file's
    /// own history is what happens when it has two answers.
    func extractionArchivePath(for sources: [FileEntry]) -> String? {
        if let own = panel.path.backend.archivePath { return own }
        let split = ArchiveTransferSources(sources)
        guard split.direct.isEmpty, split.groups.count == 1 else { return nil }
        return split.groups[0].archivePath
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

        extractArchiveSources(
            [ArchiveTransferSources.Group(archivePath: archivePath, members: sources)]
        ) { [weak self] localSources in
            self?.finishArchiveExtraction(localSources: localSources, destination: destination)
        }
    }

    /// Extract every group's members to disk and hand back the real files, in group order.
    ///
    /// One archive at a time and one `withArchivePassphrase` apiece — the encryption question, the
    /// prompt and its retry all live there, shared with preview, member-open and nested-archive
    /// entry, so an archive unlocked by any of them is not asked about again. Recursive rather than
    /// a loop because that funnel is callback-shaped: each group's success carries the accumulated
    /// files into the next.
    ///
    /// A group that **fails outright** stops the run and reports, matching F5: an extraction that
    /// threw is a damaged archive or a refused name, and continuing would hand the queue a subset
    /// while the alert says something went wrong. A member that merely never landed is dropped by
    /// its own failed `stat` and reported by whoever counts what came back.
    func extractArchiveSources(
        _ groups: [ArchiveTransferSources.Group],
        extracted: [FileEntry] = [],
        then continuation: @escaping @MainActor ([FileEntry]) -> Void
    ) {
        guard let group = groups.first else {
            continuation(extracted)
            return
        }
        let remaining = Array(groups.dropFirst())
        let innerPaths = group.members.map(\.path.path)
        let archivePath = group.archivePath
        let backend = backend
        let encoding = declaredNameEncoding(forArchiveAt: archivePath)
        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            try await BlockingWork.run { () -> Result<[FileEntry], any Error> in
                Result {
                    let extraction = try ArchiveExtractor.extract(
                        innerPaths: innerPaths,
                        fromArchiveAt: archivePath,
                        passphrase: passphrase,
                        nameEncoding: encoding
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
            self?.extractArchiveSources(
                remaining, extracted: extracted + localSources, then: continuation
            )
        } onFailure: { [weak self] error in
            guard let self else { return }
            guard !offerNameEncoding(after: error, forArchiveAt: archivePath) else { return }
            presentOperationFailure(
                message: String(localized: "Couldn’t extract from the archive"),
                detail: describe(error)
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
