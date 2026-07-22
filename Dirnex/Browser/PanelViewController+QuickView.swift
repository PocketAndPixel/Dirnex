import AppKit
import DirnexCore

/// The pane's share of Quick View (PLAN.md §M4, extended by §M11): surfacing a preview over *this*
/// pane's file list, and reporting what the cursor is on so another surface can preview it.
///
/// The window (`BrowserWindowController`) owns the mode and decides where the preview goes — the
/// inactive pane at ⌃Q, over both panes at ⌃⇧Q, over the whole window at ⌃⌥Q. The preview itself
/// is a `QuickViewPreviewView`, identical at every size; a pane only knows how to (a) keep one
/// pinned over its own list and (b) report the file under its cursor.
extension PanelViewController {
    /// Cover this pane's file list with a live preview of `url` (the file under the *other* pane's
    /// cursor). Lazily builds the surface on first use. `nil` clears it to a blank preview — the
    /// cursor is on `..` or an empty directory, so there is nothing to show.
    func showQuickViewPreview(of url: URL?) {
        let preview = ensureQuickViewPreview()
        preview.isHidden = false
        preview.show(url)
    }

    /// Uncover the file list, restoring the normal pane. Safe to call when Quick View was never
    /// shown for this pane.
    func hideQuickViewPreview() {
        quickViewPreview?.isHidden = true
        quickViewPreview?.clear()
    }

    /// The file under this pane's cursor as a URL, for another surface to preview — `nil` on the
    /// `..` row or in an empty directory. A local entry resolves at once; an archive member
    /// resolves to its extracted temp file once cached (nil until `prepareArchivePreview` lands
    /// it), so the window re-drives the preview when the extraction finishes.
    var quickViewSourceURL: URL? {
        guard !cursorOnParentRow, let entry = panel.currentEntry else { return nil }
        if entry.path.backend == .local { return entry.path.localURL }
        guard let member = previewableArchiveMember else { return nil }
        return host?.archivePreviewCache.cachedURL(for: member)
    }

    /// Move the cursor `delta` rows — what ← / → and the two-finger swipe both do while a
    /// full-size Quick View covers the list (PLAN.md §M11). Routed through the table so the
    /// selection mirror, the chrome and the preview all update by the one existing path.
    func stepCursor(by delta: Int) {
        tableView.moveCursor(by: delta)
    }

    /// What a full-size preview's header says about this pane's cursor (PLAN.md §M11). Counts
    /// *table rows* rather than entries, `..` included, so the position matches the list the
    /// preview is covering. `nil` in an empty directory, where there is nothing to name.
    var quickViewCaption: QuickViewCaption? {
        let rows = tableView.numberOfRows
        guard rows > 0 else { return nil }
        if cursorOnParentRow { return QuickViewCaption(name: "..", position: 1, count: rows) }
        guard let entry = panel.currentEntry else { return nil }
        return QuickViewCaption(
            name: entry.name,
            position: row(forEntryIndex: panel.cursor) + 1,
            count: rows
        )
    }

    /// Build this pane's preview surface on first use and pin it over the scroll view. The list
    /// under it stays laid out (only covered), so uncovering it needs no relayout. Backed with the
    /// dynamic `textBackgroundColor` so a preview that doesn't fill the pane can't let the table
    /// bleed through.
    private func ensureQuickViewPreview() -> QuickViewPreviewView {
        if let preview = quickViewPreview { return preview }
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        view.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            preview.topAnchor.constraint(equalTo: scrollView.topAnchor),
            preview.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
        quickViewPreview = preview
        return preview
    }
}
