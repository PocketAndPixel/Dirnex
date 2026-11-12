import AppKit
import DirnexCore

/// Clipboard copy/paste of files (⌘C / ⌘V / ⌥⌘V) — the keyboard-only sibling of drag-drop
/// (`PanelViewController+Drop`) and the F5/F6 transfers (`PanelViewController+Copy`).
///
/// ⌘C writes the marked set to the *general* pasteboard as one item per row (`PanelPasteboard`):
/// Dirnex's own `PasteboardPayload` always, and `public.file-url` beside it for a row that has one
/// — so a local copy is still Finder's shape and pastes there as it always did, while a row on a
/// server travels too. ⌘V pastes into the focused pane as a copy, ⌥⌘V as a move ("Move Items Here",
/// Finder's wording). Both hand the real byte work to `submitTransfer`, so conflicts, progress (the
/// window's queue bar), and the both-panes refresh are shared with every other transfer.
///
/// Until M23 this was file URLs alone, which is why ⌘C was refused outright on every connected
/// account: a row on a server has no `file://` path, and writing one would have named a file on this
/// Mac that does not exist.
///
/// Copy and paste answer to the *standard* `copy:` / `paste:` responder actions, so they land
/// on this pane only when the file table is first responder; while a name/path field is being
/// edited the field editor is first responder and handles ⌘C/⌘V as ordinary text
/// copy/paste. ⌥⌘V has no standard selector, so it stays custom and is gated off in text
/// fields by `validateMenuItem`.
///
/// Because the pasteboard is app-global and paste always targets the *focused* pane, ⌘C in one
/// pane then ⌘V in the other copies/moves between the panels. Pasting back into the source
/// folder is a duplicate: `submitTransfer` renames it "<name> copy", matching Finder's ⌘C/⌘V.
///
/// In a **tree** the destination is the folder the cursor's row lives in, not the tree's root —
/// `creationDirectory`, the same rule F7 New Folder and ⇧F4 Edit File follow. That is what makes
/// pasting *into* a source's own subtree reachable at all (put the cursor inside a folder you just
/// copied), which `TransferAdmission.pasteAdmits` was already written to refuse.
extension PanelViewController {
    // MARK: - Menu / key actions (dispatched to the focused pane via the responder chain)

    @objc func copy(_ sender: Any?) {
        // ⌘C writes one item per row: Dirnex's own payload always, and `public.file-url` beside it
        // for a row that has one, so a local copy still pastes in Finder exactly as it always did
        // (PLAN.md §M23 Slice 2). Until M23 this refused a remote pane outright — the board could
        // only carry `file://` URLs and a row on a server has none — which left the gesture a Mac
        // user reaches for without thinking silently dead on every connected account.
        PanelPasteboard.write(clipboardTargets(), to: .general)
    }

    @objc func paste(_ sender: Any?) {
        performPaste(kind: .copy)
    }

    @objc func pasteAndMoveFromClipboard(_ sender: Any?) {
        performPaste(kind: .move)
    }

    // MARK: - Enablement

    /// The rows ⌘C would put on the board: the marked set, else the cursor row.
    ///
    /// Nothing is excluded any more. Slice 2 held archive members back because nothing that *read*
    /// the board knew to route one to an extraction, so a paste would have failed inside the queue;
    /// Slice 5's `resolveTransferSources` is that reader, and `PanelPasteboard` now carries every
    /// row it can encode. Kept as its own name rather than folded into `selectionTargets` because
    /// the two answer different questions — this is "what would go on the board", and a row the
    /// board could not carry would belong here again the day one exists.
    func clipboardTargets() -> [FileEntry] {
        selectionTargets()
    }

    /// Whether ⌘C has anything to place on the board — the gate in `validateMenuItem`.
    var canCopyToClipboard: Bool {
        !clipboardTargets().isEmpty
    }

    /// Where a paste or a drop lands in this pane, or `nil` when files cannot land here at all.
    ///
    /// Three questions, and the third is the one M23 adds. There has to be a **real directory**
    /// (`creationDirectory` — `nil` for the merged Trash and a results listing, the CloudDocs
    /// container for the merged iCloud row, and in a tree the folder the cursor's row lives in); the
    /// backend that owns *that* directory has to be writable; and it has to be somewhere bytes can
    /// actually arrive (`VFSBackendID.receivesFiles`).
    ///
    /// **An S3 account pane is why the third is not implied by the second.** It carries `.write` —
    /// F7 there creates a bucket — and `creationDirectory` answers for it, so without this check
    /// Paste lights up over a list of buckets and the job fails *inside the queue*, minutes later
    /// and with the pane looking fine, instead of the menu item simply being gray.
    var pasteDestination: VFSPath? {
        guard let destination = creationDirectory,
              backend.capabilities(for: destination).contains(.write),
              destination.backend.receivesFiles else { return nil }
        return destination
    }

    /// Whether this pane can receive a paste or a drop — the gate in `validateMenuItem`.
    var canReceiveFiles: Bool { pasteDestination != nil }

    /// Whether the general pasteboard holds something a paste could act on — the gate for enabling
    /// Paste / Move Items Here in `validateMenuItem`.
    ///
    /// Named for files rather than for URLs since M23: the board may hold Dirnex's own payload, file
    /// URLs from another app, or (for an all-local copy of ours) both. Testing only for URLs grayed
    /// Paste out after a ⌘C on a server, which is the case the milestone exists to fix.
    func clipboardHasFiles() -> Bool {
        PanelPasteboard.holdsSomethingToTransfer(.general)
    }

    // MARK: - Flow

    /// Read whatever the pasteboard offers — our own payload for preference, else another app's
    /// file URLs — and transfer it into this pane's destination directory: the pane's own in a flat
    /// list, the cursor's level in a tree. A move
    /// silently drops any item already living there (moving a file onto itself is a no-op);
    /// a copy keeps them — landing on itself becomes a "<name> copy" duplicate downstream.
    /// Either kind drops a source that would recurse into its own subtree (pasting a folder
    /// inside itself), mirroring the drop guard.
    private func performPaste(kind: FileOperation.Kind) {
        // ⌘V and ⌥⌘V into a browsed archive add the board's rows into it by repacking (PLAN.md §M4,
        // and §M36 for the move). A nested archive is read-only (`isWritableArchive`), so it falls
        // through to the no-op below: `pasteDestination` has no directory to offer for one.
        if isWritableArchive {
            pasteIntoArchive(kind: kind)
            return
        }
        // The cursor decides the destination in a tree, and the table's selection is the live cursor
        // (`PanelViewController+CreateTarget`).
        reconcileCursorFromTable()
        // `nil` where there is no real destination directory; the CloudDocs container when the pane
        // is showing the merged iCloud listing, whose root is a place files can be put (§M9); and in
        // a tree, the folder the cursor's row lives in — so a paste lands where the user is pointing
        // rather than back at the root, the same rule F7 and ⇧F4 follow.
        guard let destination = pasteDestination else { return }
        guard let offered = PanelPasteboard.sources(in: .general) else { return }

        // `resolveTransferSources` owns the off-main stat, the two carriers' difference, and the
        // extraction an archive member needs before the queue can see it — all of it shared with
        // drop, so the two gestures cannot end up reading one board two ways.
        resolveTransferSources(
            offered,
            admitting: { TransferAdmission.pasteAdmits($0, into: destination, kind: kind) },
            then: { [weak self] sources in
                guard let self, !sources.isEmpty else { return }
                submitTransfer(kind: kind, sources: sources, destination: destination)
                // The paste makes this the active pane; the window controller re-lists both panes
                // as the queued job finishes (matching drop, which also skips an eager reload).
                host?.panelDidBecomeActive(self)
                focusTable()
            }
        )
    }
}
