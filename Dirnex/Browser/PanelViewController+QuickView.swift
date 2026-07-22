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
    /// Does nothing, and says so, when there is no file that way — see `canStepCursor(by:)`.
    @discardableResult
    func stepCursor(by delta: Int) -> Bool {
        guard canStepCursor(by: delta) else { return false }
        tableView.moveCursor(by: delta)
        return true
    }

    /// Whether a `delta`-row step lands on a file. The list a full-size Quick View walks is the
    /// *files* — `..` is a way out, not something to preview, and previewing it is a blank surface
    /// with no list beside it to explain why. So the parent row is not a stop, and the two ends of
    /// the list are hard: `moveCursor`'s clamp would otherwise let a swipe past the last file
    /// re-deal the file already on screen, which reads as a list that never ends.
    func canStepCursor(by delta: Int) -> Bool {
        let target = tableView.selectedRow + delta
        return target >= parentRowCount && target < tableView.numberOfRows
    }

    /// Step off the `..` row onto the first file, for a mode that is about to cover the list
    /// (PLAN.md §M11). Only the way in needs it: arriving in a directory already lands on an entry,
    /// and neither ← / → nor the swipe will go back to `..`.
    func stepOffParentRowForQuickView() {
        guard cursorOnParentRow, !panel.isEmpty else { return }
        tableView.selectRowIndexes(IndexSet(integer: parentRowCount), byExtendingSelection: false)
        tableView.scrollRowToVisible(parentRowCount)
    }

    /// What a full-size preview's header says about this pane's cursor (PLAN.md §M11). Counts
    /// entries, not table rows: `..` is not one of the files being flipped through, so counting it
    /// would put the last file at "7 of 8" with no eighth to reach. `nil` when there is nothing to
    /// name — an empty directory, or the `..` row of one.
    var quickViewCaption: QuickViewCaption? {
        guard !cursorOnParentRow, let entry = panel.currentEntry else { return nil }
        return QuickViewCaption(name: entry.name, position: panel.cursor + 1, count: panel.count)
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
