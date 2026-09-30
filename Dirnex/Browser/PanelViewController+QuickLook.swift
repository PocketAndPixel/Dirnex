import AppKit
import DirnexCore
import Quartz

/// Quick Look integration for a file pane (PLAN.md §M1 "Quick Look on … Cmd+Y").
///
/// The pane is the Quick Look controller while its table is first responder; it
/// previews the marked set (starting at the cursor) or, with nothing marked, the file
/// under the cursor — matching Finder. The panel is refreshed live as the cursor and
/// marks change via `refreshQuickLookIfVisible()`.
///
/// A pane whose rows are *not* files on this Mac — a browsed archive, or a server — offers exactly
/// one: the row under the cursor, once something has extracted or fetched it. See
/// ``previewsCursorFileOnly`` for why, and ``quickLookURL(for:)`` for the resolver both of those
/// cases share with the Quick View surfaces rather than restating.
extension PanelViewController: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ previewPanel: QLPreviewPanel!) {
        // Quick Look drives these NSResponder hooks on the main thread, but the Quartz
        // category imports them as nonisolated — assert the isolation we already have.
        MainActor.assumeIsolated {
            previewPanel.dataSource = self
            previewPanel.delegate = self
            if let current = panel.currentEntry,
               let index = quickLookItems().firstIndex(of: current) {
                previewPanel.currentPreviewItemIndex = index
            }
        }
    }

    override func endPreviewPanelControl(_ previewPanel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            previewPanel.dataSource = nil
            previewPanel.delegate = nil
            // The panel has stopped following this pane, so a transfer started on its behalf is for
            // a surface nobody is looking at — unless Quick View is up, which follows the same
            // cursor and is served by that same one transfer.
            if host?.isQuickViewEnabled != true { host?.remoteFileCache.cancelAutomaticFetch() }
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookItems().count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let items = quickLookItems()
        guard index >= 0, index < items.count, let url = quickLookURL(for: items[index]) else { return nil }
        return url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: any QLPreviewItem) -> NSRect {
        // Zoom the preview to/from the cursor row for a native feel.
        let row = tableView.selectedRow
        guard row >= 0, let window = tableView.window else { return .zero }
        let inWindow = tableView.convert(tableView.rect(ofRow: row), to: nil)
        return window.convertToScreen(inWindow)
    }

    /// Refresh an open preview after the cursor or marks change so it tracks the pane. Inside a
    /// browsed archive the member under the cursor is extracted on demand, then this runs again
    /// to show it — `prepareArchivePreview` no-ops once it's cached, so there is no loop.
    ///
    /// **The remote counterpart is here too, and the reason it is safe is not the reason the
    /// extraction is.** An archive member is already on this Mac, so extracting one costs a
    /// subprocess; a server object costs a billed request and somebody's bandwidth, and this method
    /// runs on every cursor movement. `prepareRemotePreview` is therefore bounded where
    /// `prepareArchivePreview` needs no bound at all — a settle delay, a size cap that *declines*
    /// rather than asking, and abandonment when the cursor leaves (PLAN.md §M21 Slice 10). It
    /// re-drives this method itself when the bytes land, so nothing here has to pass a callback.
    ///
    /// What is still true is that a row over the cap leaves this panel on its own empty state:
    /// Quick Look is Apple's window and cannot be handed the placeholder card the pane's own
    /// surfaces draw, with its size and its Download button. That is the remaining cost, and it is
    /// smaller than the one it replaced — the panel used to be empty for *every* un-fetched row.
    func refreshQuickLookIfVisible() {
        guard isQuickLookFollowingThisPane, let previewPanel = QLPreviewPanel.shared() else {
            return
        }
        previewPanel.reloadData()
        prepareArchivePreview { [weak self] in self?.refreshQuickLookIfVisible() }
        prepareRemotePreview()
    }

    /// Whether the shared preview panel is currently showing *this* pane's cursor.
    ///
    /// Its own property because two quite different questions rest on it: whether a refresh applies
    /// here at all, and — from `endRemotePreview` — whether a transfer some other surface has just
    /// stopped wanting is still wanted by this one. `QLPreviewPanel.shared()` *creates* the panel,
    /// so the existence check has to come first (docs/NOTES.md ▸ AppKit).
    var isQuickLookFollowingThisPane: Bool {
        QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared()?.isVisible == true
            && (QLPreviewPanel.shared()?.currentController as? PanelViewController) === self
    }

    /// What Quick Look previews: where the rows are not files on this Mac, just the one under the
    /// cursor once its bytes are here; otherwise the marked set (with the cursor as the starting
    /// item), or failing that the file under the cursor. Entries that resolve to no on-disk URL are
    /// dropped.
    private func quickLookItems() -> [FileEntry] {
        if previewsCursorFileOnly {
            guard !cursorOnParentRow, let current = panel.currentEntry,
                  quickLookURL(for: current) != nil else { return [] }
            return [current]
        }
        let marked = panel.selectedEntries.filter { $0.path.backend == .local }
        if !marked.isEmpty { return marked }
        if !cursorOnParentRow, let current = panel.currentEntry, current.path.backend == .local {
            return [current]
        }
        return []
    }

    /// Whether Quick Look can only ever be handed *one* file here — the row under the cursor.
    ///
    /// True wherever the rows are not files on this Mac. An archive member must be extracted and a
    /// remote object downloaded before anything can preview it, and only the cursor's own is ever
    /// brought down: a marked set would cost a subprocess per row inside an archive and, on a
    /// server, a billed request and somebody's bandwidth per row (PLAN.md §M21 Slice 10).
    /// Asked of the **row** rather than of the pane, for the reason `remoteFileUnderCursor` is: a
    /// results tab's container reads `search:` while its rows are archive members or objects on a
    /// server, so the pane-keyed spelling answered `false` there — and the branch it then took keeps
    /// only `.local` rows, so ⌘Y on any hit of an M22 search reported **“No items selected”**. With
    /// nothing under the cursor there is no row to ask, and the pane's own kind is what is left.
    var previewsCursorFileOnly: Bool {
        guard !cursorOnParentRow, let entry = panel.currentEntry else {
            return isArchive || panel.path.backend.isRemoteConnection
        }
        return entry.path.backend != .local
    }

    /// The on-disk URL Quick Look previews for `entry`: its real URL for a file on this Mac, and for
    /// anything else the copy that was extracted or fetched for it — `nil` until one lands, which is
    /// the ordinary state of a server row nobody has asked for yet.
    ///
    /// Everything but the local case defers to ``quickViewSourceURL``, the pane's one answer to
    /// "where are this row's bytes", instead of resolving it a second time — and that is exactly
    /// what this file had got wrong. The funnel grew a remote branch at Slice 10 while this resolver
    /// kept its own archive-only copy, so ⌘Y on a server file reported **“No items selected”** for a
    /// row the Quick View surface beside it was previewing perfectly, having spent the fetch on the
    /// way (the key does ask for one). Found by pressing the key the placeholder card itself names.
    /// One question, two spellings, and the compiler checks neither (docs/NOTES.md ▸ AppKit).
    private func quickLookURL(for entry: FileEntry) -> URL? {
        if entry.path.backend == .local { return entry.path.localURL }
        // The funnel answers for the *cursor*, which is the only row these panes offer (above).
        guard entry.id == panel.currentEntry?.id else { return nil }
        return quickViewSourceURL
    }
}
