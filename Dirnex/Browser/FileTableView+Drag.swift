import AppKit

extension FileTableView {
    /// Called from inside `mouseDown`'s tracking loop the moment the press becomes a drag, so before
    /// the press's queued pressure events are delivered. Measured 2026-10-18: 1 ms before `mouseDown`
    /// returned, and ahead of the data source's own `willBeginAt`.
    ///
    /// **A grab on a marked row drags every marked row, and the session has to be built that way.**
    /// The table is single-selection, so AppKit hands over one item, for the grabbed row. Widening it
    /// afterwards, by rewriting the session's board in `willBeginAt`, carried local files and lost
    /// every promise: measured 2026-10-24 dragging two marked WebDAV rows into Finder, three drags
    /// fetched nothing and dropped nothing, while one unmarked row and two marked local zips dropped
    /// first time. A promise is fulfilled only as one of the session's own items, so the items are
    /// replaced here, before the session exists.
    override func beginDraggingSession(
        with items: [NSDraggingItem],
        event: NSEvent,
        source: any NSDraggingSource
    ) -> NSDraggingSession {
        forceClick.disarm()
        let row = row(at: convert(event.locationInWindow, from: nil))
        var dragged = items
        if row >= 0, items.count == 1, let grabbed = items.first,
           let writers = inputDelegate?.fileTable(self, dragWritersFromRow: row) {
            dragged = Self.draggingItems(for: writers, replacing: grabbed)
        }
        let session = super.beginDraggingSession(with: dragged, event: event, source: source)
        if row >= 0 { inputDelegate?.fileTable(self, didBegin: session, fromRow: row) }
        return session
    }

    /// The pointer moved during a drag, which arrives ahead of whatever app it just entered reading
    /// the board (measured, 6 ms in Teams), so that app can still be offered something else.
    ///
    /// `@objc` by name because `NSDraggingSource` is an inherited conformance, whose optional members
    /// Swift does not match by signature, and AppKit dispatches this through `respondsToSelector:`.
    /// `NSTableView` has no implementation of its own for this to replace.
    @objc(draggingSession:movedToPoint:)
    func draggingSessionMoved(_ session: NSDraggingSession, to screenPoint: NSPoint) {
        inputDelegate?.fileTableDraggingSessionMoved(self)
    }

    /// One item per writer, all at the grabbed row's frame and only the first with its picture, so a
    /// drag of the marked set looks as a one-row drag always has (the image stacking was never built).
    static func draggingItems(
        for writers: [any NSPasteboardWriting],
        replacing grabbed: NSDraggingItem
    ) -> [NSDraggingItem] {
        writers.enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.draggingFrame = grabbed.draggingFrame
            // Not `setDraggingFrame(_:contents: nil)`, which still leaves the item an image component.
            item.imageComponentsProvider = index == 0 ? grabbed.imageComponentsProvider : nil
            return item
        }
    }
}
