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
/// copied), which `pasteAdmits` was already written to refuse.
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

    /// The rows ⌘C would put on the board: the marked set, else the cursor row, minus anything the
    /// pasteboard cannot carry yet (an archive member — see `PanelPasteboard.canWrite`).
    ///
    /// Filtered per **entry** rather than per pane, like tagging and Open With: a results tab is a
    /// virtual pane whose rows can be local files, server objects and archive members at once, so
    /// the pane's own backend answers for none of them.
    func clipboardTargets() -> [FileEntry] {
        selectionTargets().filter(PanelPasteboard.canWrite)
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
        // ⌘V into a browsed archive adds the pasteboard files into it (PLAN.md §M4). Copy only:
        // ⌥⌘V move-paste into an archive isn't supported this pass (gated in `validateMenuItem`).
        // A nested archive is read-only (`isWritableArchive`), so it falls through to the no-op.
        if isWritableArchive {
            if kind == .copy { pasteIntoArchive() }
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

        let backend = backend
        Task {
            // Resolve off-main into the entries the engine copies, dropping any that would be a
            // no-op or a recursion into the destination. The two carriers differ in what is still
            // owed — ours is already a snapshot, a foreign board is URLs that have to be stat'ed —
            // which is why `PanelPasteboard.Sources` keeps them apart rather than normalizing.
            let sources = await BlockingWork.run { () -> [FileEntry] in
                switch offered {
                case let .locations(entries):
                    // No stat: the payload carries what the engine reads, so pasting twenty objects
                    // off a server costs no round trips (PLAN.md §M23). A source that has since
                    // vanished is reported per item by the engine, exactly as it is for F5.
                    return entries.filter { pasteAdmits($0.path, into: destination, kind: kind) }
                case let .fileURLs(urls):
                    return urls.compactMap { url -> FileEntry? in
                        let source = VFSPath.local(url.path)
                        guard pasteAdmits(source, into: destination, kind: kind) else { return nil }
                        return try? backend.stat(at: source)
                    }
                }
            }
            guard !sources.isEmpty else { return }
            submitTransfer(kind: kind, sources: sources, destination: destination)
            // The paste makes this the active pane; the window controller re-lists both panes
            // as the queued job finishes (matching drop, which also skips an eager reload).
            host?.panelDidBecomeActive(self)
            focusTable()
        }
    }
}

/// Whether `source` may be pasted into `destination` at all.
///
/// Free function so the `@Sendable` off-main closure can call it without capturing the view
/// controller. Two rules, and they are not the same rule:
///
/// - A **recursion** — the destination is the folder itself or lives inside its subtree — is refused
///   for either kind. `TransferAdmission.recurses` rather than the string comparison this file used
///   to carry: that one had no backend in it, so a local `/tmp` read as an ancestor of an SFTP
///   `/tmp/x` and an ordinary cross-backend paste was silently refused (PLAN.md §M23).
/// - A **same-folder move** is dropped, because moving a file onto itself is nothing. A same-folder
///   *copy* is kept on purpose: that is the duplicate gesture, and `submit` renames it "<name> copy"
///   without a prompt, matching Finder.
private func pasteAdmits(
    _ source: VFSPath,
    into destination: VFSPath,
    kind: FileOperation.Kind
) -> Bool {
    if kind == .move, source.parent == destination { return false }
    return !TransferAdmission.recurses(source: source, into: destination)
}
