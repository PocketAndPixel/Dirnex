import AppKit
import DirnexCore

/// Clipboard copy/paste of files (⌘C / ⌘V / ⌥⌘V) — the keyboard-only sibling of drag-drop
/// (`PanelViewController+Drop`) and the F5/F6 transfers (`PanelViewController+Copy`).
///
/// ⌘C writes the marked set's file URLs to the *general* pasteboard, the same shape Finder
/// uses, so a copy here pastes in Finder and vice-versa. ⌘V pastes them into the focused pane
/// as a copy, ⌥⌘V as a move ("Move Items Here", Finder's wording). Both hand the real byte
/// work to `submitTransfer`, so conflicts, progress (the window's queue bar), and the
/// both-panes refresh are shared with every other transfer.
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
extension PanelViewController {
    // MARK: - Menu / key actions (dispatched to the focused pane via the responder chain)

    @objc func copy(_ sender: Any?) {
        // ⌘C places *local* file URLs on the pasteboard (Finder's shape). A remote SFTP entry has
        // no local URL, so copying it would write a bogus `file://` path — F5 is the copy-*out*
        // route for remote files. (Search-results entries carry real on-disk paths, so they copy.)
        guard !panel.path.backend.isSFTP else { return }
        let targets = selectionTargets()
        guard !targets.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(targets.map { $0.path.localURL as NSURL })
    }

    @objc func paste(_ sender: Any?) {
        performPaste(kind: .copy)
    }

    @objc func pasteAndMoveFromClipboard(_ sender: Any?) {
        performPaste(kind: .move)
    }

    // MARK: - Enablement

    /// Whether the general pasteboard currently holds at least one file URL — the gate for
    /// enabling Paste / Move Items Here in `validateMenuItem`.
    func clipboardHasFiles() -> Bool {
        NSPasteboard.general.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }

    // MARK: - Flow

    /// Read the pasteboard's file URLs and transfer them into this pane's directory. A move
    /// silently drops any item already living here (moving a file onto itself is a no-op);
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
        guard !isVirtualDirectory else { return } // no real destination directory here
        guard backend.capabilities.contains(.write) else { return }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL], !urls.isEmpty else { return }

        let destination = panel.path
        let backend = backend
        Task {
            // Stat the pasted items off-main into the entries the engine copies, dropping any
            // that have vanished or that would be a no-op / recursion into the destination.
            let sources = await Task.detached(priority: .userInitiated) { () -> [FileEntry] in
                urls.compactMap { url -> FileEntry? in
                    let source = VFSPath.local(url.path)
                    if kind == .move, source.parent == destination { return nil }
                    if pasteRecurses(source: source, into: destination) { return nil }
                    return try? backend.stat(at: source)
                }
            }.value
            guard !sources.isEmpty else { return }
            submitTransfer(kind: kind, sources: sources, destination: destination)
            // The paste makes this the active pane; the window controller re-lists both panes
            // as the queued job finishes (matching drop, which also skips an eager reload).
            host?.panelDidBecomeActive(self)
            focusTable()
        }
    }
}

/// Whether transferring `source` into `destination` would recurse — the destination is the
/// folder itself or lives inside its subtree. Free function so the `@Sendable` off-main stat
/// closure can call it without capturing the view controller. Mirrors `PanelViewController
/// +Drop`'s guard; a same-folder duplicate (destination is the source's *parent*) is allowed.
private func pasteRecurses(source: VFSPath, into destination: VFSPath) -> Bool {
    destination == source || destination.path.hasPrefix(source.path + "/")
}
