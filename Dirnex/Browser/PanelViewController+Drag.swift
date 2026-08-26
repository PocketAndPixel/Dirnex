import AppKit
import DirnexCore

/// Drag-out support (PLAN.md §M1 "Drag out to other apps") plus the source half of
/// drag *in* (PLAN.md §M2 "Drop onto panel"). A file pane is both a drag source and,
/// via `PanelViewController+Drop`, a drop target.
///
/// These are additional `NSTableViewDataSource` methods; the conformance is declared in
/// `PanelViewController+Table`.
///
/// Since M23 every row is draggable **within Dirnex**, a server's included, because the board
/// carries a `PasteboardPayload` beside the file URL. A row with no local URL still drags nowhere
/// *outside* Dirnex — another app is handed nothing it can read — which is Slice 4's job
/// (`NSFilePromiseProvider`), not this one's.
extension PanelViewController {
    /// Configure the pane as a drag source and register it to receive file-URL drops.
    ///
    /// External drags (to Finder or other apps) offer only `.copy`, so a drag out can
    /// never move or delete the original. Local drags (pane-to-pane, or onto a subfolder
    /// of the same pane) offer both `.copy` and `.move` so `PanelViewController+Drop` can
    /// honor Finder's copy-vs-move conventions.
    func configureDragging() {
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        // Both carriers: Dirnex's own payload (which can name a row on a server) and the file URLs
        // Finder, Mail and everything else send. Ours is listed first because it is the richer one.
        tableView.registerForDraggedTypes(PanelPasteboard.acceptedDragTypes)
    }

    /// The pasteboard item for a dragged row — the same item ⌘C would write for it
    /// (`PanelPasteboard.items`): Dirnex's own payload, plus `public.file-url` when the row has a
    /// real one. `nil` for the synthetic `..` row (no backing entry) and for an archive member,
    /// which nothing yet knows how to route out of a drop (PLAN.md §M23 Slice 5).
    ///
    /// One definition shared with the clipboard rather than a second one here: the two gestures have
    /// to put the identical thing on the board, and this is where they would otherwise drift.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = entryIndex(forRow: row),
              let entry = panel.displayedEntry(at: index) else { return nil }
        return PanelPasteboard.items(for: [entry]).first
    }

    /// When the grab starts on a marked file, drag the whole marked set (Total Commander
    /// semantics: operate on the selection); a grab on an unmarked file drags just that
    /// file. The table is single-selection, so AppKit only ever offers the one cursor row
    /// — we widen the pasteboard to every marked entry here.
    ///
    /// The drag image still shows just the grabbed row; a stacked multi-file image would
    /// require driving the whole session by hand, which isn't worth it for M1.
    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        guard panel.selectionCount > 1 else { return }
        let grabbedMarkedFile = rowIndexes.contains { row in
            guard let index = entryIndex(forRow: row),
                  let entry = panel.displayedEntry(at: index) else { return false }
            return panel.isMarked(entry)
        }
        guard grabbedMarkedFile else { return }
        // Rebuilt, never re-used: `-[NSPasteboard writeObjects:]` **raises** if handed an item that
        // has already been written to a board (probed fatally 2026-08-26), and AppKit has just
        // written one per row through `pasteboardWriterForRow` above. `PanelPasteboard.write` mints
        // fresh items, and leaves the board alone when the marked set holds nothing it can carry.
        PanelPasteboard.write(panel.selectedEntries, to: session.draggingPasteboard)
    }
}
