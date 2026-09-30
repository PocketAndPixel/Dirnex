import AppKit
import DirnexCore

/// Drop *in* — receiving a drag onto a pane as a real copy or move through the window's
/// shared operation queue (PLAN.md §M2 "Drop onto panel = real copy/move through the
/// queue"). Files can arrive from the other pane, from the same pane onto a subfolder, or
/// from an external app such as Finder.
///
/// These are the receiving `NSTableViewDataSource` drop methods; the conformance is
/// declared in `PanelViewController+Table` and the source (drag-out) half lives in
/// `PanelViewController+Drag`. All byte work runs through `submitTransfer`
/// (`PanelViewController+Copy`), so conflict handling, progress, and the both-panes
/// refresh are shared with F5/F6.
///
/// Since M23 a drop can land on a **connected account** as well as on this disk, and can carry rows
/// that have no `file://` URL at all — so the destination gate is `VFSBackendID.receivesFiles` (the
/// one ⌘V and F5 read) and the sources arrive through `PanelPasteboard`. Two rules that were written
/// out by hand here moved to the tested `TransferAdmission` at the same time, because both were
/// wrong across backends and one of them decides whether the original is deleted.
extension PanelViewController {
    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let plan = dropPlan(info, row: row, dropOperation: dropOperation) else {
            return []
        }
        // Highlight the specific folder row for an "into this folder" drop, else the whole
        // pane (row -1, `.on`) for a drop into the current directory.
        tableView.setDropRow(plan.highlightRow ?? -1, dropOperation: .on)
        return plan.operation
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let plan = dropPlan(info, row: row, dropOperation: dropOperation) else {
            return false
        }
        let destination = plan.destination
        let kind = plan.kind
        // No filter: `dropPlan` has already refused the whole gesture if anything would recurse or
        // if every item already lives here, so there is nothing left to drop per item. The shared
        // funnel owns the off-main stat a foreign board owes and the extraction an archive member
        // needs — a URL that no longer stats (deleted between drag start and drop) simply falls out
        // rather than failing the operation.
        resolveTransferSources(plan.sources) { [weak self] sources in
            guard let self, !sources.isEmpty else { return }
            submitTransfer(kind: kind, sources: sources, destination: destination)
            // A drop makes this pane the active one, matching Finder's focus-follows-drop.
            host?.panelDidBecomeActive(self)
            focusTable()
        }
        return true
    }

    // MARK: - Plan

    /// The resolved intent of a drag hovering over (or released on) this pane, or `nil`
    /// when the drop is invalid or a no-op. Computed identically in `validateDrop` (for
    /// the cursor feedback) and `acceptDrop` (for the real work).
    /// Internal rather than private so the drop tests can drive the plan directly — it touches no
    /// table and no drag session, so the decision is fully reachable without presenting one, which
    /// is what keeps this suite off the sheet-teardown crash this project has paid for once.
    struct DropPlan {
        let kind: FileOperation.Kind
        /// The AppKit operation reported back for the drag cursor badge.
        let operation: NSDragOperation
        let destination: VFSPath
        /// What the board offered, kept in its own shape so `acceptDrop` knows whether it still
        /// owes a `stat` (see `PanelPasteboard.Sources`).
        let sources: PanelPasteboard.Sources
        /// A directory row to highlight for an "into this folder" drop, or `nil` to
        /// highlight the whole pane (a drop into the current directory).
        let highlightRow: Int?
    }

    /// `modifiers` defaults to the keys held right now, which is what every caller wants and what
    /// makes it the one thing about a drop a headless test could not reach: `NSEvent.modifierFlags`
    /// is the real keyboard, and a synthetic event is not a gesture (docs/NOTES.md ▸ AppKit). It is
    /// a parameter so the ⌘-forced case can be pinned, because that is the only case where the
    /// archive rule below changes an answer — everything else about an archive drop is already a
    /// backend crossing, so it copies whatever the rule says.
    func dropPlan(
        _ info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation,
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) -> DropPlan? {
        // A drop needs a real directory to land in — never a virtual pane (search results, the
        // Trash, or a read-only archive whose write support lands in a later M4 pass).
        // `writeDirectory` is that directory, and it is what makes the merged iCloud listing a drop
        // target: its root is the CloudDocs container underneath (PLAN.md §M9).
        guard let base = writeDirectory else { return nil }
        guard let offered = PanelPasteboard.sources(in: info.draggingPasteboard) else { return nil }

        let (destination, highlightRow) = dropDestination(
            row: row, dropOperation: dropOperation, base: base
        )
        // Validated on the **destination**, not on `base`. They are the same in a flat listing and
        // are not in a tree, where a folder row can belong to another backend entirely — a bucket's
        // contents drawn under an S3 *account* root, whose own rows nothing can be dropped into
        // (PLAN.md §M23). `receivesFiles` is the same gate ⌘V and F5 read.
        guard backend.capabilities(for: destination).contains(.write),
              destination.backend.receivesFiles else { return nil }

        let sources = droppedPaths(offered)
        guard !sources.isEmpty else { return nil }

        // No-op: every dropped item already lives in the destination (e.g. dragging a
        // pane's own files onto its own background). Reject so the cursor shows "no drop".
        if sources.allSatisfy({ $0.parent == destination }) { return nil }

        // Never drop a folder onto itself or into its own subtree — that would recurse.
        // `TransferAdmission` rather than a string comparison: the one this file used to carry had
        // no backend in it, so a local `/tmp` read as an ancestor of an SFTP `/tmp/x` and an
        // ordinary cross-backend drop was refused with no message.
        let recurses = sources.contains {
            TransferAdmission.recurses(source: $0, into: destination)
        }
        if recurses { return nil }

        guard let kind = resolvedKind(
            mask: info.draggingSourceOperationMask,
            modifiers: modifiers,
            sources: sources,
            destination: destination
        ) else { return nil }

        return DropPlan(
            kind: kind,
            operation: kind == .copy ? .copy : .move,
            destination: destination,
            sources: offered,
            highlightRow: highlightRow
        )
    }

    /// Where a drop lands: into a directory row it's released *on* (a real subfolder or
    /// the `..` parent, for a move up a level), else into the pane's current directory.
    private func dropDestination(
        row: Int,
        dropOperation: NSTableView.DropOperation,
        base: VFSPath
    ) -> (destination: VFSPath, highlightRow: Int?) {
        if dropOperation == .on {
            if isParentRow(row), let parent = panel.parentPath {
                return (parent, row)
            }
            if let index = entryIndex(forRow: row),
               let entry = panel.displayedEntry(at: index),
               entry.isDirectoryLike {
                return (entry.path, row)
            }
        }
        return (base, nil)
    }

    /// Copy or move, following Finder's conventions: an explicit Option forces copy and
    /// Command forces move; otherwise the default is move within a volume and copy across
    /// volumes (so dragging to another disk never silently deletes the source). Constrained
    /// by what the drag source actually offers (`mask`) **and by what the sources permit**: an
    /// archive member can only ever be copied, since the container is read-only and a move would
    /// have nothing to remove afterwards.
    ///
    /// That rule rides in through the *offer* rather than as a branch of its own, which is what
    /// makes a ⌘-forced move over an archive member fall back to a copy for free — "a modifier the
    /// source does not offer is ignored" is already `TransferAdmission.kind`'s documented behaviour.
    /// One member answers for the whole drop: a drag is one gesture with one kind, and copying
    /// everything is the direction that cannot delete anything.
    private func resolvedKind(
        mask: NSDragOperation,
        modifiers: NSEvent.ModifierFlags,
        sources: [VFSPath],
        destination: VFSPath
    ) -> FileOperation.Kind? {
        TransferAdmission.kind(
            offer: TransferAdmission.DragOffer(
                allowsCopy: mask.contains(.copy) || mask.contains(.generic),
                allowsMove: mask.contains(.move) && TransferAdmission.allowsMove(from: sources)
            ),
            modifiers: TransferAdmission.DragModifiers(
                forcesCopy: modifiers.contains(.option),
                forcesMove: modifiers.contains(.command)
            ),
            sharesVolume: sharesVolume(sources, with: destination)
        )
    }

    /// Whether the sources sit on the same physical volume as the destination — the first
    /// source is taken as representative to keep this cheap during hover (a drag is almost
    /// always from one folder).
    ///
    /// **This decides whether the user's original is deleted**, which is why the rule is the tested
    /// `TransferAdmission.sharesVolume` rather than a comparison here. The version this file used to
    /// carry read a `nil` volume as "one indistinguishable volume" and returned `true` — correct for
    /// the queue's scheduler, and inverted here. `CompositeBackend` answers `nil` for *every*
    /// non-local path, so the moment a remote pane became a drop target (this slice) an unmodified
    /// drag from this Mac onto a server would have been called a same-volume move and the local
    /// original removed (PLAN.md §M23).
    private func sharesVolume(_ sources: [VFSPath], with destination: VFSPath) -> Bool {
        guard let first = sources.first else { return false }
        return TransferAdmission.sharesVolume(first, destination) {
            backend.volumeIdentifier(for: $0)
        }
    }

    /// The locations a drop would move, whichever carrier they arrived on.
    private func droppedPaths(_ sources: PanelPasteboard.Sources) -> [VFSPath] {
        switch sources {
        case let .locations(entries): entries.map(\.path)
        case let .fileURLs(urls): urls.map { VFSPath.local($0.path) }
        }
    }
}
