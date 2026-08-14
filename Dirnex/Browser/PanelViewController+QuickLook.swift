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
    /// **There is deliberately no remote counterpart to that extraction, and adding one here would
    /// be the bug.** This runs on every cursor movement, so a fetch in it would spend a billed
    /// request because the cursor passed over a row — the rule the whole slice is built on
    /// (PLAN.md §M21 Slice 10). The cost is that arrowing onto a server row nobody has fetched
    /// leaves the panel on its own empty state: Quick Look is Apple's window and cannot be handed
    /// the placeholder card the pane's own surfaces draw. `openRemotePreview` belongs to the key
    /// somebody pressed, which is `fileTableToggleQuickLook`, and to nothing else.
    func refreshQuickLookIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let previewPanel = QLPreviewPanel.shared(),
              previewPanel.isVisible,
              (previewPanel.currentController as? PanelViewController) === self else { return }
        previewPanel.reloadData()
        prepareArchivePreview { [weak self] in self?.refreshQuickLookIfVisible() }
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
    var previewsCursorFileOnly: Bool {
        isArchive || panel.path.backend.isRemoteConnection
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
