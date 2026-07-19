import AppKit
import DirnexCore

/// Drag-out support (PLAN.md §M1 "Drag out to other apps") plus the source half of
/// drag *in* (PLAN.md §M2 "Drop onto panel"). A file pane is both a drag source and,
/// via `PanelViewController+Drop`, a drop target.
///
/// These are additional `NSTableViewDataSource` methods; the conformance is declared in
/// `PanelViewController+Table`.
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
        tableView.registerForDraggedTypes([.fileURL])
    }

    /// The pasteboard item for a dragged row: the entry's file URL, or `nil` for the
    /// synthetic `..` row (no backing entry) or a non-local entry (an archive member has no
    /// on-disk URL to hand another app until extraction lands in a later M4 pass).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = entryIndex(forRow: row) else { return nil }
        let entry = panel.model[index]
        guard entry.path.backend == .local else { return nil }
        return entry.path.localURL as NSURL
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
            guard let index = entryIndex(forRow: row) else { return false }
            return panel.isMarked(panel.model[index])
        }
        guard grabbedMarkedFile else { return }
        let urls = panel.selectedEntries.map { $0.path.localURL as NSURL }
        session.draggingPasteboard.clearContents()
        session.draggingPasteboard.writeObjects(urls)
    }
}
