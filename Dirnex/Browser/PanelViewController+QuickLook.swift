import AppKit
import DirnexCore
import Quartz

/// Quick Look integration for a file pane (PLAN.md §M1 "Quick Look on … Cmd+Y").
///
/// The pane is the Quick Look controller while its table is first responder; it
/// previews the marked set (starting at the cursor) or, with nothing marked, the file
/// under the cursor — matching Finder. The panel is refreshed live as the cursor and
/// marks change via `refreshQuickLookIfVisible()`.
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
    func refreshQuickLookIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let previewPanel = QLPreviewPanel.shared(),
              previewPanel.isVisible,
              (previewPanel.currentController as? PanelViewController) === self else { return }
        previewPanel.reloadData()
        prepareArchivePreview { [weak self] in self?.refreshQuickLookIfVisible() }
    }

    /// What Quick Look previews: inside a browsed archive, just the member under the cursor once
    /// it's been extracted; otherwise the marked set (with the cursor as the starting item), or
    /// failing that the file under the cursor. Entries that resolve to no on-disk URL are dropped.
    private func quickLookItems() -> [FileEntry] {
        if isArchive {
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

    /// The on-disk URL Quick Look previews for `entry`: its real URL for a local file, or the
    /// extracted temp file for an archive member once cached (`nil` until extraction lands).
    private func quickLookURL(for entry: FileEntry) -> URL? {
        if entry.path.backend == .local { return entry.path.localURL }
        guard !entry.isDirectoryLike, let archivePath = panel.path.backend.archivePath else { return nil }
        let member = ArchiveMember(archivePath: archivePath, innerPath: entry.path.path)
        return host?.archivePreviewCache.cachedURL(for: member)
    }
}
