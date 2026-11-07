import AppKit
import DirnexCore

/// Adding files *into* a browsed archive (PLAN.md §M4 "Archive writes: add/delete inside zip"), the
/// second half of the archive-write engine and the symmetric inverse of F8 delete.
///
/// It reuses the same extract → edit → repack → atomic-swap rewrite as delete (`ArchiveWriter.add`,
/// which copies the items into the extracted tree). A same-named member is a *replace*, so any
/// collisions are confirmed up front before the archive is touched. Add is a copy: a move adds the
/// items and then trashes the originals (recoverable + undoable via the standard Trash journal),
/// and the rewrite itself is undoable too — one ⌘Z per half, since they are two operations on two
/// different files.
///
/// **One way in, whichever gesture arrives** (PLAN.md §M36). F5, F6, ⌘V, ⌥⌘V and a drop all reach
/// ``beginArchiveAdd(_:into:kind:originalsIn:)`` with the rows they were handed, and it owns the three
/// things those used to get differently or not at all:
///
/// - **What may land**, through `TransferAdmission.pasteAdmits`. A folder holding the archive is a
///   recursion, which F6 used to add and then trash, archive and all.
/// - **Where the bytes come from.** The archive is rewritten from files on this disk, and until M36
///   F5 from a server pane handed `ArchiveWriter` the *server's* paths as if they were local ones —
///   which copies whatever file this Mac has at that path, or fails naming one it does not. Every
///   source now goes through `materialize`, the funnel ⌥F5 stages its sources through: a local row
///   as it is, a row on a server downloaded (a folder as a queue job with a bar and Stop), a member
///   of another archive extracted.
/// - **What the move removes**: the rows the user moved, never the staged copies that stood in for
///   them.
///
/// `self` is always the *destination* archive pane.
extension PanelViewController {
    /// Add `sources` into `destination`, a folder inside this pane's archive. `kind == .move` removes
    /// the originals afterwards, through `sourcePane` when that pane is showing them; `.copy` leaves
    /// them. A no-op when the archive takes no writes, or when nothing is admitted.
    ///
    /// `undo` is where the rewrite keeps the archive it displaced. Every gesture takes the default,
    /// the app's own store; a test passes a scratch one, since in the test host the default is the
    /// developer's own Application Support (the compare window's save takes the same seam).
    func beginArchiveAdd(
        _ sources: [FileEntry],
        into destination: VFSPath,
        kind: FileOperation.Kind,
        originalsIn sourcePane: PanelViewController?,
        undo: @escaping @Sendable () -> ArchiveUndoStorage.Request = { ArchiveUndoStorage.request() }
    ) {
        guard let archivePath = destination.backend.archivePath,
              archiveAcceptsWrites(atOnDiskPath: archivePath) else { return }
        // The last line of defence rather than the only one: each gesture has refused a recursion
        // in its own way already (F5's sentence, a drop's no-drop cursor), and a paste filters here.
        let adding = sources.filter {
            TransferAdmission.pasteAdmits($0.path, into: destination, kind: kind)
        }
        guard !adding.isEmpty else { return }
        let request = ArchiveAddRequest(
            sources: adding,
            destination: destination,
            archivePath: archivePath,
            kind: kind,
            originalsPane: sourcePane,
            undo: undo
        )
        let backend = backend
        Task {
            // Gather the destination's real member names (unfiltered — a hidden member still
            // collides on disk) to warn before overwriting anything — and before anything is
            // downloaded or extracted, so a user who backs out has paid nothing.
            let existingNames = await BlockingWork.run { () -> [String] in
                ((try? backend.listDirectory(at: destination)) ?? []).map(\.name)
            }
            let collisions = ArchiveMutation.collidingNames(
                addingNames: adding.map(\.name),
                existingNames: existingNames
            )
            guard !collisions.isEmpty else {
                stageArchiveAdd(request)
                return
            }
            confirmArchiveReplace(names: collisions, archiveAt: archivePath) { [weak self] in
                self?.stageArchiveAdd(request)
            }
        }
    }

    /// ⌘V and ⌥⌘V into this archive pane: read whatever the board offers — Dirnex's own rows from
    /// anywhere, or another app's file URLs — and add it to the folder the pane is showing.
    ///
    /// Until M36 this read file URLs alone, so a ⌘C on a server or inside another archive enabled
    /// Paste here and then did nothing at all, and ⌥⌘V was gray.
    func pasteIntoArchive(kind: FileOperation.Kind) {
        guard isWritableArchive, let offered = PanelPasteboard.sources(in: .general) else { return }
        addOffered(offered, into: panel.path, kind: kind)
    }

    /// Add what a board offered — the step ⌘V and a drop share, so the two cannot read one board
    /// two ways. The stat a foreign board owes runs off the main actor; the payload's rows need none.
    func addOffered(
        _ offered: PanelPasteboard.Sources,
        into destination: VFSPath,
        kind: FileOperation.Kind
    ) {
        readOfferedSources(
            offered,
            admitting: { TransferAdmission.pasteAdmits($0, into: destination, kind: kind) },
            then: { [weak self] sources in
                guard let self, !sources.isEmpty else { return }
                beginArchiveAdd(
                    sources, into: destination, kind: kind,
                    originalsIn: paneShowingOriginals(of: sources)
                )
                // The paste or drop makes this the active pane, matching the local flows.
                host?.panelDidBecomeActive(self)
                focusTable()
            }
        )
    }

    /// The pane to remove a move's originals through: the other pane when it is showing where they
    /// are — where a drag or a ⌘C in a two-pane window nearly always came from — so its listing and
    /// its marks follow the move, and otherwise this one.
    ///
    /// Never a pane that is merely *there*: the removal clears the marks of whichever pane runs it,
    /// and a Finder drag with ⌘ held has nothing to do with what the other pane has marked.
    private func paneShowingOriginals(of sources: [FileEntry]) -> PanelViewController {
        guard let other = host?.panelCounterpart(of: self),
              sources.contains(where: { $0.path.parent == other.panel.path }) else { return self }
        return other
    }

    // MARK: - Stage

    /// What one add was asked to do, carried through the confirmation and the staging.
    struct ArchiveAddRequest {
        let sources: [FileEntry]
        let destination: VFSPath
        let archivePath: String
        let kind: FileOperation.Kind
        let originalsPane: PanelViewController?
        let undo: @Sendable () -> ArchiveUndoStorage.Request
    }

    /// Bring every source down to a file on this disk, then rewrite the archive with them.
    ///
    /// `includingPlaceholders` for ⌥F5's reason: `ArchiveWriter` copies with `FileManager`, which
    /// would read through an evicted cloud file mid-rewrite, and the gesture is what fetches.
    private func stageArchiveAdd(_ request: ArchiveAddRequest) {
        let name = (request.archivePath as NSString).lastPathComponent
        let sources = request.sources
        materialize(sources, for: .addToArchive, includingPlaceholders: true) {
            sources.count == 1
                ? String(localized: "Couldn’t add “\(sources[0].name)”")
                : String(localized: "Couldn’t add \(sources.count) items to “\(name)”")
        } then: { [weak self] urls in
            self?.runArchiveAdd(urls, for: request)
        }
    }

    // MARK: - Confirm

    /// F5 or F6 with the archive itself marked, or a folder holding it: say so rather than add it
    /// into itself, and — for F6 — rather than move the archive to the Trash once it had been.
    func presentArchiveAddRecursion(into destination: VFSPath) {
        let archiveName = ((destination.backend.archivePath ?? "") as NSString).lastPathComponent
        presentOperationFailure(
            message: String(
                localized: "Can’t add to “\(archiveName)”",
                comment: """
                Alert title when F5/F6 into a browsed archive is refused because the archive itself \
                is among the items being added; %@ is the archive's file name.
                """
            ),
            detail: String(
                localized: "The archive is one of the items being added, or inside one of them.",
                comment: """
                Alert detail for the same refusal: a marked item is the archive file, or a folder \
                that contains it, so the archive would end up inside itself.
                """
            )
        )
    }

    private func confirmArchiveReplace(
        names: [String],
        archiveAt archivePath: String,
        proceed: @escaping () -> Void
    ) {
        let archiveName = (archivePath as NSString).lastPathComponent
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = names.count == 1
            ? String(localized: "Replace “\(names[0])” in “\(archiveName)”?")
            : String(localized: "Replace \(names.count) items in “\(archiveName)”?")
        alert.informativeText = ArchiveUndoStorage.willBeUndoable(archiveAt: archivePath)
            ? String(
                localized: """
                An item with the same name is already in the archive. Replacing rewrites the \
                archive; Undo puts it back.
                """,
                comment: """
                Body of the replace-in-archive confirmation when the rewrite will be undoable — \
                Dirnex keeps a copy of the archive as it was.
                """
            )
            : String(
                localized: """
                An item with the same name is already in the archive. Replacing rewrites the \
                archive and can’t be undone.
                """,
                comment: """
                Body of the replace-in-archive confirmation when the archive is too large for \
                Dirnex to keep a copy of, so the rewrite cannot be reversed.
                """
            )
        alert.addButton(withTitle: String(localized: "Replace"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.enableEscapeToCancel()

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    // MARK: - Run

    /// Rewrite the archive from `staged`, the files on this disk standing for `request.sources` in
    /// the same order.
    ///
    /// The two lists are kept apart on purpose. The archive is written from `staged`, since that is
    /// where the bytes are; a move removes `request.sources`, since those are what the user moved — a
    /// server's file removed through its downloaded copy would remove nothing, and the copy removed
    /// as if it were the original would report a move that left the original where it was. A folder
    /// staged off a server is swept on every ending, because no cache adopts one
    /// (`RemoteFileCache.sweepStagedTrees`, which leaves anything it did not stage alone).
    private func runArchiveAdd(_ staged: [URL], for request: ArchiveAddRequest) {
        let sources = request.sources
        let innerDirectory = request.destination.path
        let archivePath = request.archivePath
        let kind = request.kind
        let sourcePane = request.originalsPane
        let undo = request.undo
        let localPaths = staged.map(\.path)
        let name = (archivePath as NSString).lastPathComponent
        let encoding = declaredNameEncoding(forArchiveAt: archivePath)
        // As with delete: an encrypted archive rewrites through libarchive, and the passphrase comes
        // from the one funnel that asks once per archive and retries on a typo.
        withArchivePassphrase(forArchiveAt: archivePath) { passphrase in
            try await BlockingWork.run {
                Result {
                    try ArchiveWriter.add(
                        localPaths: localPaths,
                        toInnerDirectory: innerDirectory,
                        ofArchiveAt: archivePath,
                        passphrase: passphrase,
                        undo: undo(),
                        nameEncoding: encoding
                    )
                }
            }.get()
        } onSuccess: { [weak self] snapshot in
            RemoteFileCache.sweepStagedTrees(staged)
            guard let self else { return }
            // Read before this pane takes focus below: F6 was pressed in the originals' pane, which
            // gets it back once they are gone, while a paste or a drop made *this* pane the active
            // one and keeps it there (seen live 2026-11-08: ⌥⌘V left the other pane focused).
            let originalsHadFocus = sourcePane?.isActivePanel ?? false
            // The mounted TOC is now stale — drop it so the re-list re-reads the rewritten archive.
            (backend as? CompositeBackend)?.invalidateMountedArchive(at: archivePath)
            journalArchiveRewrite(snapshot)
            panel.clearSelection()
            refreshArchiveDirectory()
            focusTable()
            // A move: the archive add is a copy, so remove the originals now that it succeeded.
            if kind == .move {
                (sourcePane ?? self).removeArchiveMoveOriginals(
                    sources,
                    takingFocus: originalsHadFocus
                )
            }
        } onFailure: { [weak self] error in
            RemoteFileCache.sweepStagedTrees(staged)
            guard let self else { return }
            guard !offerNameEncoding(after: error, forArchiveAt: archivePath) else { return }
            presentOperationFailure(
                message: sources.count == 1
                    ? String(localized: "Couldn’t add “\(sources[0].name)”")
                    : String(localized: "Couldn’t add \(sources.count) items to “\(name)”"),
                detail: describe(error)
            )
        } onCancel: {
            RemoteFileCache.sweepStagedTrees(staged)
        }
    }

    /// Trash the originals of a move once they've been copied into the archive — the "move" half
    /// (add-into-archive is a copy, so the sources are removed here). To the Trash, so it's
    /// recoverable, and journaled, so this half is undoable even though the rewrite isn't. Runs on
    /// the pane showing the originals when there is one, so its listing follows. On a server, which
    /// keeps no Trash, this is the confirmed permanent delete below. `takingFocus` is false when that
    /// pane is not where the user is: after a paste or a drop, focus stays on the archive.
    ///
    /// **A volume that keeps no Trash refuses this, and that used to make F6 silently mean F5.**
    /// The originals were trashed through a `try?`, so a network share's refusal
    /// (``LocalBackend/trashFailure(_:path:)``, reported 2026-08-25) removed nothing and said
    /// nothing — the archive held the items and so did the folder they came from. Now the refusal
    /// is offered as the permanent delete that would finish the move, and a "no" is *reported*
    /// rather than left to be discovered: the gesture really did end as a copy.
    ///
    /// Note what makes the question safe to ask here. The archive rewrite has already succeeded, so
    /// the items exist in two places and declining is a good outcome rather than a lost one — the
    /// opposite of F8, where declining leaves the user where they started.
    func removeArchiveMoveOriginals(_ entries: [FileEntry], takingFocus: Bool = true) {
        let paths = entries.map(\.path)
        let backend = backend
        Task {
            let outcome = await BlockingWork.run {
                DeletePass.run(paths, using: backend, permanent: false)
            }
            panel.clearSelection()
            // F6 into an archive from search results: the originals left, so their rows go too.
            noteSearchHitsDeleted(outcome.deleted(from: paths), permanent: false)
            refreshCurrentDirectory()
            if takingFocus { focusTable() }
            noteTrashed(outcome.restorations)
            // A real failure (a permission problem, a read-only folder) is reported for the same
            // reason F8 reports one: the originals are still there, and only the user can act on it.
            if !outcome.failures.isEmpty {
                presentDeletionFailures(outcome.failures, permanent: false)
            }
            offerPermanentDelete(
                forVolumeWithoutTrash: outcome.refused,
                confirmed: { [weak self] refused in self?.runDelete(refused, permanent: true) },
                declined: { [weak self] in self?.reportArchiveMoveKeptOriginals(outcome.refused) }
            )
        }
    }

    /// Say that the move ended as a copy. The status line rather than an alert: nothing failed, the
    /// archive holds everything it was asked to hold, and the user has just answered a question — a
    /// second sheet to acknowledge their own answer is noise.
    ///
    /// One sentence, because this label truncates its *tail* in silence when it overruns and the
    /// tail is where an explanation lives (docs/NOTES.md ▸ Localization). No file name is
    /// interpolated for the same reason: a name here is unbounded, and the count is what the user
    /// needs. Measured in the label's own font across all fourteen catalogs: 310 pt for the single
    /// form (widest, ja) and 332 pt for the plural (ru, at a three-digit count), against a pane of
    /// ~542 pt.
    private func reportArchiveMoveKeptOriginals(_ paths: [VFSPath]) {
        showTransientStatus(
            paths.count == 1
                ? String(
                    localized: "Copied into the archive — the original is still here.",
                    comment: """
                    Status line after an F6 move into an archive whose single original could not be \
                    moved to the Trash (the volume keeps none) and the user declined to delete it.
                    """
                )
                : String(
                    localized: "Copied into the archive — \(paths.count) originals are still here.",
                    comment: """
                    Status line after an F6 move into an archive whose originals could not be moved \
                    to the Trash (the volume keeps none) and the user declined to delete them; \
                    %lld is the count. Plural.
                    """
                )
        )
    }
}
