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
/// carries a `PasteboardPayload` beside the file URL — and since Slice 4 a row whose bytes are on a
/// server drags *out* as well, as an `NSFilePromiseProvider` another app can accept. Which of the
/// two writers a row gets is `PanelPasteboard.dragWriters`' decision, made per row, so a mixed
/// selection is one drag rather than two.
extension PanelViewController {
    /// Configure the pane as a drag source and register it to receive file-URL drops.
    ///
    /// External drags (to Finder or other apps) offer only `.copy`, so a drag out can
    /// never move or delete the original — which since Slice 4 covers a promised row too, where a
    /// move would mean deleting a file on a server on the strength of somebody else's drop.
    /// Local drags (pane-to-pane, or onto a subfolder
    /// of the same pane) offer both `.copy` and `.move` so `PanelViewController+Drop` can
    /// honor Finder's copy-vs-move conventions.
    func configureDragging() {
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        // Both carriers: Dirnex's own payload (which can name a row on a server) and the file URLs
        // Finder, Mail and everything else send. Ours is listed first because it is the richer one.
        tableView.registerForDraggedTypes(PanelPasteboard.acceptedDragTypes)
    }

    /// The pasteboard writer for a dragged row: Dirnex's own payload always, plus `public.file-url`
    /// for a row with real bytes here and a **file promise** for one whose bytes are on a server.
    /// `nil` for the synthetic `..` row (no backing entry) and for an archive member, which nothing
    /// yet knows how to route out of a drop (PLAN.md §M23 Slice 5).
    ///
    /// One definition shared with the clipboard rather than a second one here: ⌘C and a drag have to
    /// put the identical payload on the board, and this is where they would otherwise drift.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = entryIndex(forRow: row),
              let entry = panel.displayedEntry(at: index) else { return nil }
        return PanelPasteboard.dragWriters(for: [entry], promisedTo: self).first
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
        // written one per row through `pasteboardWriterForRow` above. `PanelPasteboard.writeDrag`
        // mints fresh writers — promises included, so a marked *remote* row survives the widening
        // rather than the multi-row drag quietly becoming local-only — and leaves the board alone
        // when the marked set holds nothing it can carry.
        PanelPasteboard.writeDrag(
            panel.selectedEntries,
            promisedTo: self,
            to: session.draggingPasteboard
        )
    }
}
