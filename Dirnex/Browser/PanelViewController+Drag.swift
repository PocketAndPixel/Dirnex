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
/// server drags *out* as well, as an `NSFilePromiseProvider` Finder can accept, and into any other
/// app as a real file once `RemoteDragHandoffController` has brought it down. Which of the two
/// writers a row gets is `PanelPasteboard.dragWriters`' decision, made per row, so a mixed selection
/// is one drag rather than two.
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
    /// `nil` only for the synthetic `..` row, which has no backing entry.
    ///
    /// An **archive member** is promised too since PLAN.md §M36 Slice 2, and extracted where a
    /// server's file is fetched — unless its archive is locked this session, when it drags on its
    /// payload alone and another app is offered nothing (`DragOutRoute`, decision A).
    ///
    /// One definition shared with the clipboard rather than a second one here: ⌘C and a drag have to
    /// put the identical payload on the board, and this is where they would otherwise drift.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let index = entryIndex(forRow: row),
              let entry = panel.displayedEntry(at: index) else { return nil }
        return PanelPasteboard.dragWriters(
            for: [entry], routes: dragOutRoutes(for: [entry]), promisedTo: self
        ).first
    }

    /// When the grab starts on a marked file, drag the whole marked set (Total Commander
    /// semantics: operate on the selection); a grab on an unmarked file drags just that
    /// file. The table is single-selection, so AppKit only ever offers the grabbed row, and the
    /// table swaps in these writers before the session starts (`FileTableView+Drag` says why it
    /// cannot be later).
    ///
    /// Fresh writers, never the row's own: `-[NSPasteboard writeObjects:]` **raises** if handed an
    /// item that has already been written to a board (probed fatally 2026-08-26). `nil` when the
    /// marked set holds nothing a drag can carry, which leaves the grabbed row to drag alone.
    func fileTable(
        _ tableView: FileTableView,
        dragWritersFromRow row: Int
    ) -> [any NSPasteboardWriting]? {
        guard let entries = markedSetDragged(fromRow: row) else { return nil }
        let writers = PanelPasteboard.dragWriters(
            for: entries, routes: dragOutRoutes(for: entries), promisedTo: self
        )
        return writers.isEmpty ? nil : writers
    }

    /// The marked set, when a grab on `row` drags all of it rather than the one row.
    private func markedSetDragged(fromRow row: Int) -> [FileEntry]? {
        guard panel.selectionCount > 1,
              let index = entryIndex(forRow: row),
              let entry = panel.displayedEntry(at: index),
              panel.isMarked(entry) else { return nil }
        return panel.selectedEntries
    }

    // MARK: - A row on a server, on its way to another app

    /// Watch a drag that holds a row on a server or inside an archive, because Finder's promise is no
    /// use to most apps — or a row of a locked archive, whose staying behind has to be explained.
    func fileTable(_ tableView: FileTableView, didBegin session: NSDraggingSession, fromRow row: Int) {
        dragHandoff = nil
        guard let cache = host?.remoteFileCache, let entries = entriesDragged(fromRow: row) else { return }
        let routes = dragOutRoutes(for: entries)
        guard routes.values.contains(
            where: { $0.isPromised || $0 == .insideDirnexOnly(.lockedArchive) }
        )
        else { return }
        let status = RemoteDragStatus(session: session)
        let extractsOnly = !routes.values.contains(.download)
        dragHandoff = RemoteDragHandoffController(
            board: session.draggingPasteboard,
            entries: entries,
            cache: cache,
            backend: backend,
            showStatus: { status.show($0) },
            onLanded: { [weak self] in
                guard let self, let cursor = remoteFileUnderCursor,
                      entries.contains(where: { $0.path == cursor.path }) else { return }
                host?.panelCursorDidChange(self)
                refreshQuickLookIfVisible()
            },
            onFailure: { [weak self] error in
                self?.presentOperationFailure(
                    message: extractsOnly
                        ? String(localized: "Couldn’t extract from the archive")
                        : String(
                            localized: "Couldn’t copy this item from the server",
                            comment: """
                            Alert title when a file dragged out of a server to another app can't be downloaded.
                            """
                        ),
                    detail: self?.describe(error) ?? ""
                )
            },
            offer: DragOutOffer(
                routes: routes,
                extractions: dragOutExtractions(for: entries, routes: routes),
                alreadyHere: { [weak self] in self?.materializedURL(for: $0) },
                onLockedRowsLeaving: { [weak self] in
                    self?.reportLockedDragRows(entries, routes: routes)
                }
            )
        )
    }

    /// Say why a member of a locked archive went nowhere: the first time the pointer was over another
    /// app, which is the moment the row was left out. The way to unlock is the one every gesture
    /// already has, opening or previewing a file in the archive, which asks once for the session.
    private func reportLockedDragRows(_ entries: [FileEntry], routes: [VFSPath: DragOutRoute]) {
        guard let archive = entries.first(where: {
            routes[$0.path] == .insideDirnexOnly(.lockedArchive)
        })?.path.backend.archivePath else { return }
        let name = (archive as NSString).lastPathComponent
        showTransientStatus(String(
            localized: "Open a file in “\(name)” first to drag its files out",
            comment: """
            Status line when a file of an encrypted archive is dragged toward another app before its \
            password was entered this session; %@ is the archive's name. Opening or previewing a file \
            in it asks for the password once.
            """
        ))
    }

    func fileTableDraggingSessionMoved(_ tableView: FileTableView) {
        dragHandoff?.pointerMoved()
    }

    /// What is still coming down may finish if a second try at the drop would have been free to ask
    /// for it, and it stops otherwise. Either way nothing has to be said: a stopped transfer leaves
    /// nothing behind, and one that finishes makes the next drag of the row immediate.
    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        endDragHandoff()
    }

    func endDragHandoff() {
        guard let dragHandoff else { return }
        var mayFinish = false
        if dragHandoff.isTransferring {
            mayFinish = RemoteFetchPolicy.decision(
                for: materializationPlan(for: dragHandoff.entries),
                purpose: .dragOut,
                previewLimit: AppPreferences.shared.quickViewFetchLimit
            ) == .fetch
        }
        dragHandoff.dragEnded(mayFinish: mayFinish)
    }

    /// Every row a drag grabbed on `row` carries.
    private func entriesDragged(fromRow row: Int) -> [FileEntry]? {
        if let marked = markedSetDragged(fromRow: row) { return marked }
        guard let index = entryIndex(forRow: row),
              let entry = panel.displayedEntry(at: index) else { return nil }
        return [entry]
    }
}
