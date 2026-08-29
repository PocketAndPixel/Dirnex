import AppKit
import DirnexCore

/// Synchronize Directories (PLAN.md §M5) — compare the two panes' folders and reconcile them.
/// The pane owns only the AppKit shell: it gathers the two directories, presents the
/// `SyncDirectoriesController` diff sheet, and — on commit — turns the checked decisions into
/// real work. Copies run through the window's shared `FileOperationQueue` (so a big mirror runs
/// in the background with progress, pause, and undo, exactly like F5); deletes go to the Trash
/// (recoverable and undoable). All comparison logic lives in the tested `DirnexCore.DirectorySync`.
///
/// The physical left pane is always the "left" side and the right pane the "right", regardless of
/// which one is focused, so the direction controls match the on-screen layout.
extension PanelViewController {
    // MARK: - Menu / palette action (dispatched to the focused pane via the responder chain)

    @objc func synchronizeDirectories(_ sender: Any?) {
        guard let window = host as? BrowserWindowController else { return }
        beginSync(left: window.leftPanel, right: window.rightPanel)
    }

    private func beginSync(left: PanelViewController, right: PanelViewController) {
        guard Self.canSync(left), Self.canSync(right) else {
            presentOperationFailure(
                message: String(
                    localized: "Can’t synchronize",
                    comment: "Sync failure title: a panel isn't a real folder."
                ),
                detail: String(
                    localized: """
                    Both panels must show a real folder — on this Mac or on a server you’re \
                    connected to.
                    """,
                    comment: """
                    Sync failure detail naming what a panel has to be showing. Widened at M25 \
                    Slice 5c, when a side stopped having to be on this disk.
                    """
                )
            )
            return
        }
        let leftDir = left.panel.path
        let rightDir = right.panel.path
        guard leftDir != rightDir else {
            presentOperationFailure(
                message: String(
                    localized: "The panels show the same folder",
                    comment: "Sync failure title: both panels show the same folder."
                ),
                detail: String(
                    localized: "Open a different folder in one panel to compare them.",
                    comment: "Sync failure detail: open a different folder to compare."
                )
            )
            return
        }

        // Both sides read-only leaves nothing a sync could do. Said here rather than by opening a
        // sheet whose every direction is missing, which reads as a broken control.
        let directions = SyncDirection.available(
            leftAcceptsChanges: Self.acceptsChanges(left),
            rightAcceptsChanges: Self.acceptsChanges(right)
        )
        guard !directions.isEmpty else {
            presentOperationFailure(
                message: String(
                    localized: "Can’t synchronize",
                    comment: "Sync failure title: a panel isn't a real folder."
                ),
                detail: String(
                    localized: "Neither panel can be changed, so there is nothing to reconcile.",
                    comment: """
                    Sync failure detail when both sides are read-only — two read-only buckets, say \
                    — so no direction could write anything.
                    """
                )
            )
            return
        }

        presentAsMovableWindow(makeSyncController(
            leftDir: leftDir,
            rightDir: rightDir,
            directions: directions
        ))
    }

    /// Build the sheet and hand it every closure it needs, with nothing presented.
    ///
    /// A separate step from presenting it because **a closure the panel forgets to install is a
    /// feature that silently does nothing**, and this project has shipped that twice already —
    /// M22's `subtreeListing` and M25 Slice 5b's `metadataTally`, each a forward `CompositeBackend`
    /// never made, each invisible to both green suites. A missing `onPrepareContents` here has the
    /// same shape: the sheet falls back to comparing with an empty map, which for a remote pair
    /// fails as *"The folders couldn't be compared"* — a sentence about the folders, over a wiring
    /// mistake. Reaching this through `beginSync` would mean presenting an app-modal window in the
    /// test host, so the seam is where the test can stand.
    func makeSyncController(
        leftDir: VFSPath,
        rightDir: VFSPath,
        directions: [SyncDirection]
    ) -> SyncDirectoriesController {
        let controller = SyncDirectoriesController(
            leftDir: leftDir,
            rightDir: rightDir,
            backend: backend,
            comparisons: SyncComparison.available(between: leftDir.backend, and: rightDir.backend),
            directions: directions
        )
        controller.onApply = { [weak self] decisions in
            self?.confirmAndApplySync(decisions, leftDir: leftDir, rightDir: rightDir)
        }
        controller.onCompare = { [weak self] left, right in
            self?.launchExternalDiff(comparing: left, with: right)
        }
        controller.onPrepareContents = { [weak self] entries, answer in
            self?.prepareSyncContents(entries, then: answer)
        }
        return controller
    }

    /// Bring a content comparison's candidate pairs down to real files and answer with the map the
    /// engine reads them back through (PLAN.md §M25 Slice 5d).
    ///
    /// The same funnel every other M24 gesture goes through, so the plan, the confirmation naming
    /// the total, the queued transfer with its bar and its Stop, and the report of a short set are
    /// all the ones that already exist — this adds a verb after them and no second way to fetch.
    ///
    /// **Placeholders are deliberately left alone** (`includingPlaceholders: false`), which is the
    /// one place this differs from ⌥F3 over the same bytes. An evicted cloud file cannot be *weighed*
    /// — `MaterializationPlan` excludes it, because `CloudDownloadPrompt` is its own progress surface
    /// — so fetching every one a tree walk discovered would be an unbounded download with no total in
    /// front of it. That is M14's rule unchanged: a file somebody pointed at downloads, a tree sweep
    /// refuses. `ByteComparator` then names the first one it meets and the sheet says so.
    ///
    /// The map is rebuilt from the window's caches rather than from the URLs handed back, exactly as
    /// the checksum run does: a row the plan found already cached is never fetched and is just as
    /// readable, so a map built from what moved would report it as not downloaded.
    /// Internal rather than private so the wiring can be driven directly: reaching it through the
    /// sheet would mean a test supplying its own `onPrepareContents`, which stands exactly where
    /// this code does and would prove nothing about it.
    func prepareSyncContents(
        _ entries: [FileEntry],
        then answer: @escaping @MainActor (MaterializedPaths?) -> Void
    ) {
        materialize(entries, for: .syncContents) {
            String(
                localized: "Couldn’t compare these folders",
                comment: """
                Alert title when the files a content comparison has to read can't be downloaded or \
                extracted.
                """
            )
        } onAbandon: {
            answer(nil)
        } then: { [weak self] _ in
            answer(self?.materializedPaths(for: entries) ?? MaterializedPaths())
        }
    }

    /// A pane can take part in a sync when it shows a **real, re-listable, readable directory** —
    /// this disk or a connected account, never a virtual listing and never an archive.
    ///
    /// The `backend == .local` this used to require went at M25 Slice 5c. Nothing about walking two
    /// trees and reconciling them needs either side to be on this disk: the comparison already takes
    /// two backends, the copies already run through the queue, and what a *delete* means on each
    /// side is now asked per path rather than assumed (``SyncDeletePlan``). What replaces it is the
    /// narrower thing that was always meant — a place whose directories can be listed again.
    ///
    /// Two exclusions carry their own reasons. An **S3 account** pane is `isRemoteConnection` and is
    /// not a folder: its rows are buckets, and there is no verb for putting a file in an account
    /// (``VFSBackendID/acceptsUploads``). An **archive** is left out because a sync deletes, and
    /// deleting a member rewrites the whole container with nothing the journal can undo — a stated
    /// limit rather than a missing branch (PLAN.md §M25, smaller than a milestone).
    ///
    /// Asked with `capabilities(for:)` rather than `capabilities`: the pane holds a
    /// `CompositeBackend`, whose backend-wide set is the *local* backend's whatever the pane is
    /// showing, so the shorter spelling answered for this disk on every remote pane (docs/NOTES.md
    /// ▸ Design lessons, the fifth of that family).
    static func canSync(_ pane: PanelViewController) -> Bool {
        let path = pane.panel.path
        guard path.backend == .local || path.backend.isRemoteConnection else { return false }
        guard !path.backend.isS3Account else { return false }
        return pane.backend.capabilities(for: path).contains(.read)
    }

    /// Whether this side can be *changed* — whether a copy can land there and a delete can happen.
    ///
    /// Both halves are needed and they answer different questions: `receivesFiles` is about the
    /// backend having an upload primitive at all, and `.write` is about this particular location
    /// permitting one. It feeds ``SyncDirection/available(leftAcceptsChanges:rightAcceptsChanges:)``,
    /// so a read-only side loses the directions that would write to it and keeps the ones that read.
    static func acceptsChanges(_ pane: PanelViewController) -> Bool {
        let path = pane.panel.path
        return path.backend.receivesFiles && pane.backend.capabilities(for: path).contains(.write)
    }

    /// Whether Synchronize Directories should be enabled: two real local folders, and not the
    /// same one (nothing to reconcile against itself).
    var canSynchronize: Bool {
        guard let window = host as? BrowserWindowController else { return false }
        return Self.canSync(window.leftPanel)
            && Self.canSync(window.rightPanel)
            && window.leftPanel.panel.path != window.rightPanel.panel.path
    }

    // MARK: - Apply

    /// Confirm any deletions (a mirror can remove files), then run the checked decisions.
    ///
    /// **What a delete means is now asked per path**, because the two sides can be two backends and
    /// only one of them may have a Trash. Until M25 Slice 5c both were on this disk and one sentence
    /// covered them — *"…will move N items to the Trash. You can restore them from the Trash later."*
    /// — which is a straight lie about a server, where `deleteStrategy` degrades to `.permanent` and
    /// the files are gone. It is the worst-placed lie available: it is the sentence somebody reads
    /// *while deciding*. ``SyncDeletePlan`` splits the counts, and a mixed run — a local pane against
    /// an account, which is the ordinary shape — says both halves.
    private func confirmAndApplySync(
        _ decisions: [SyncDirectoriesController.Decision],
        leftDir: VFSPath,
        rightDir: VFSPath
    ) {
        let backend = backend
        let plan = SyncDeletePlan(paths: Self.deleteTargets(in: decisions)) {
            backend.capabilities(for: $0).deleteStrategy
        }
        guard !plan.isEmpty else {
            applySync(decisions, deleting: plan, leftDir: leftDir, rightDir: rightDir)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = plan.permanent.isEmpty ? .warning : .critical
        alert.messageText = Self.deleteConfirmationTitle(for: plan)
        alert.informativeText = Self.deleteConfirmationBody(for: plan)
        alert.addButton(withTitle: String(
            localized: "Synchronize",
            comment: "Confirm button of the sync delete prompt and the sync sheet."
        ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))
        alert.enableEscapeToCancel()
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applySync(decisions, deleting: plan, leftDir: leftDir, rightDir: rightDir)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    /// The paths a set of decisions will delete, in row order.
    ///
    /// One derivation, read by the confirmation *and* by the run, so the sentence cannot count a
    /// different set from the one that is deleted — the trap this project keeps meeting whenever a
    /// gesture works out what a run will do and the run works it out again (docs/NOTES.md).
    ///
    /// Internal and static so a test can assert the sentence over a set of decisions without a pane.
    static func deleteTargets(in decisions: [SyncDirectoriesController.Decision]) -> [VFSPath] {
        decisions.compactMap { decision in
            switch decision.action {
            case .deleteLeft: decision.entry.left?.path
            case .deleteRight: decision.entry.right?.path
            default: nil
            }
        }
    }

    /// The question, which names the count and — where it differs — what will happen to it.
    ///
    /// The Trash-only wording keeps its original key, so the fourteen translations it already has
    /// survive a change that is not about them.
    static func deleteConfirmationTitle(for plan: SyncDeletePlan) -> String {
        if plan.permanent.isEmpty {
            return String(
                localized: "Synchronizing will move \(plan.toTrash.count) items to the Trash.",
                comment: "Sync delete confirmation title; %lld is the number of items. Plural."
            )
        }
        if plan.toTrash.isEmpty {
            return String(
                localized: "Synchronizing will permanently delete \(plan.permanent.count) items.",
                comment: """
                Sync delete confirmation title where no side has a Trash — every remote account, \
                and a local volume that keeps none. %lld is the number of items. Plural.
                """
            )
        }
        return String(
            localized: "Synchronizing will delete \(plan.count) items.",
            comment: """
            Sync delete confirmation title where the two sides disagree about what a delete does, \
            so the body names both halves. %lld is the total number of items. Plural.
            """
        )
    }

    /// What happens to them, one sentence per outcome.
    ///
    /// Each sentence carries **one** count, deliberately: a String Catalog can vary a plural on a
    /// single argument with no `substitutions` machinery, and a translator reading three short
    /// sentences can reorder them for their own language where one three-count sentence would pin
    /// the order (docs/NOTES.md ▸ Localization).
    static func deleteConfirmationBody(for plan: SyncDeletePlan) -> String {
        var sentences: [String] = []
        if !plan.toTrash.isEmpty, plan.permanent.isEmpty {
            sentences.append(String(
                localized: "You can restore them from the Trash later.",
                comment: "Sync delete confirmation body."
            ))
        } else if !plan.toTrash.isEmpty {
            sentences.append(String(
                localized: "\(plan.toTrash.count) items will go to the Trash.",
                comment: """
                Sync delete confirmation body, first half of a mixed run; %lld is the number of \
                items on a side that has a Trash. Plural.
                """
            ))
        }
        if !plan.permanent.isEmpty {
            sentences.append(String(
                localized: "\(plan.permanent.count) items will be deleted for good — there’s no Trash on a server.",
                comment: """
                Sync delete confirmation body naming the irreversible half; %lld is the number of \
                items on a side with no Trash, which is every remote account. Plural.
                """
            ))
        }
        if !plan.unsupported.isEmpty {
            sentences.append(String(
                localized: "\(plan.unsupported.count) items can’t be deleted where they are and will be left alone.",
                comment: """
                Sync delete confirmation body naming items on a read-only side, which the run will \
                skip; %lld is their number. Plural.
                """
            ))
        }
        return sentences.joined(separator: " ")
    }

    /// Run the checked decisions. `plan` is the one the confirmation counted, handed over rather
    /// than re-derived: the sentence somebody agreed to and the deletions that follow it must be the
    /// same set, and passing it is the only version of that a later edit cannot break.
    private func applySync(
        _ decisions: [SyncDirectoriesController.Decision],
        deleting plan: SyncDeletePlan,
        leftDir: VFSPath,
        rightDir: VFSPath
    ) {
        // Batch copies by destination directory so each folder is one queue job (multiple
        // sources → one FileOperation), and collect delete paths for a single Trash pass.
        var copyGroups: [VFSPath: [FileEntry]] = [:]
        for decision in decisions {
            switch decision.action {
            case .copyToRight:
                if let source = decision.entry.left {
                    let dest = destinationDirectory(
                        root: rightDir,
                        relativePath: decision.entry.relativePath
                    )
                    copyGroups[dest, default: []].append(source)
                }
            case .copyToLeft:
                if let source = decision.entry.right {
                    let dest = destinationDirectory(
                        root: leftDir,
                        relativePath: decision.entry.relativePath
                    )
                    copyGroups[dest, default: []].append(source)
                }
            case .deleteLeft, .deleteRight, .none, .conflict:
                break // deletes come from `deleteTargets(in:)`, the one derivation the sheet counted
            }
        }
        for (destination, sources) in copyGroups {
            submitSyncCopy(sources: sources, destination: destination)
        }
        if !plan.isEmpty { runSyncDeletes(plan) }
    }

    /// The directory a copy of the item at `relativePath` lands in, under `root`. The relative
    /// path's parent always exists on the destination side — the comparison only descends into
    /// directories present on *both* sides, so a differing item's parent is already there.
    private func destinationDirectory(root: VFSPath, relativePath: String) -> VFSPath {
        let parents = relativePath.split(separator: "/").dropLast()
        return parents.reduce(root) { $0.appending(String($1)) }
    }

    /// Enqueue one copy job under the `.overwrite` policy — the user already decided in the diff,
    /// so newer/changed items replace their counterpart without a per-file prompt (the atomic
    /// temp-swap keeps the original until the copy completes). Failures still surface via
    /// `ErrorPrompter`; the window journals the transfer for undo as the job finishes.
    private func submitSyncCopy(sources: [FileEntry], destination: VFSPath) {
        let errorPrompter = ErrorPrompter(window: view.window)
        let operation = FileOperation(
            kind: .copy,
            sources: sources,
            destinationDirectory: destination
        )
        host?.enqueue(
            operation,
            conflictPolicy: .overwrite,
            resolveConflict: nil,
            onError: { errorPrompter.resolve($0) }
        )
    }

    /// Run the sync's deletions off the main thread, journal what can be undone, and re-list both
    /// panes.
    ///
    /// **Two passes, because the plan can hold two kinds.** ``DeletePass`` takes one `permanent`
    /// flag for a whole batch, and since M25 Slice 5c a sync's two sides can be two backends: the
    /// local one keeps a Trash and no remote account does. Guessing one flag for a mixed set would
    /// either try to trash a server file (which fails) or delete a local one for good (which is
    /// worse), so the split is made in ``SyncDeletePlan`` before anything is asked and each half is
    /// run as what it is. `plan.unsupported` is deliberately not run — those items were named in the
    /// confirmation and nothing here can touch them.
    ///
    /// **A local volume that keeps no Trash refuses at run time, and that used to be silent.** The
    /// deletes ran through a `try?`, so on a network share (``LocalBackend/trashFailure(_:path:)``,
    /// reported 2026-08-25) the sync finished claiming it had removed files that were still there.
    /// That refusal cannot be anticipated — there is no pre-check, unlike a remote account's, whose
    /// answer is known from its capabilities — so it is collected across the whole run and asked
    /// about **once**, at the end: a batch may span hundreds of items, and stopping at each one to
    /// ask is not a question, it is an obstacle.
    ///
    /// Asking afterwards costs nothing, because a refusal moves nothing — every refused item is
    /// exactly where it was when the sheet goes up. The answer comes back as a plan holding only
    /// `permanent`, which can raise no second question: `removeItem` consults no Trash
    /// (``DeletePass/Outcome``).
    ///
    /// Internal rather than private so the Trash-less path can be driven directly: reaching it
    /// through the sheet would mean presenting a movable window in the test host, which wedges
    /// the run rather than failing it (docs/NOTES.md ▸ Testing).
    func runSyncDeletes(_ plan: SyncDeletePlan) {
        let backend = backend
        Task {
            let outcome = await BlockingWork.run { () -> DeletePass.Outcome in
                let trashed = DeletePass.run(plan.toTrash, using: backend, permanent: false)
                let erased = DeletePass.run(plan.permanent, using: backend, permanent: true)
                return DeletePass.Outcome(
                    failures: trashed.failures + erased.failures,
                    restorations: trashed.restorations,
                    refused: trashed.refused
                )
            }
            if let record = UndoRecord.trash(outcome.restorations.map { ($0.original, $0.trashed) }) {
                host?.recordUndoableAction(record)
            }
            if let window = host as? BrowserWindowController {
                window.leftPanel.refreshCurrentDirectory()
                window.rightPanel.refreshCurrentDirectory()
            }
            // Reported rather than swallowed: a sync that could not remove an item has left the two
            // sides unequal, which is the one thing the operation exists to fix.
            if !outcome.failures.isEmpty {
                presentDeletionFailures(outcome.failures, permanent: plan.toTrash.isEmpty)
            }
            // Last, so the sheet the user must answer is in front of any report (as in `runDelete`).
            offerPermanentDelete(forVolumeWithoutTrash: outcome.refused) { [weak self] refused in
                self?.runSyncDeletes(SyncDeletePlan(permanent: refused))
            }
        }
    }
}
