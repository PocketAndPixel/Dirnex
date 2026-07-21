import AppKit
import DirnexCore

/// Non-scrolling chrome around the file list: the path bar, the status line, and the
/// column sort indicators. Read-only with respect to `Panel` — split out to keep the
/// controller proper focused on navigation and the cursor/selection plumbing.
extension PanelViewController {
    func updateChrome() {
        pathBar.setPath(panel.path, archiveAncestry: archiveBreadcrumbAncestry())
        pathBar.setBranch(gitSnapshot?.branch)
        statusLabel.stringValue = statusText()
        // If this is the active pane and Quick View is on, the file under the cursor just
        // changed — re-drive the preview showing in the inactive pane. A no-op otherwise.
        host?.panelCursorDidChange(self)
    }

    // MARK: - Transient status

    /// Show `message` in the status line for a few seconds, in place of the item count, then let
    /// the line fall back to its normal contents. For work that happens *outside* the pane and
    /// would otherwise be invisible — a detached diff-tool launch takes seconds to draw its first
    /// window, and without a word here the app looks like it swallowed the keystroke.
    ///
    /// Deliberately not an alert: nothing here needs a decision, and a modal for "opening…" costs
    /// more than the information is worth. The message survives an intervening `updateChrome`
    /// (a background refresh must not eat it) and expires on time rather than on navigation —
    /// a few seconds of a stale note is a smaller wrong than a message the user never sees.
    func showTransientStatus(_ message: String) {
        transientStatus = message
        transientStatusToken += 1
        let token = transientStatusToken
        updateChrome()
        let expiry = DispatchTime.now() + Self.transientStatusDuration
        DispatchQueue.main.asyncAfter(deadline: expiry) { [weak self] in
            // A newer message has since taken the line; its own expiry owns the clearing.
            guard let self, transientStatusToken == token else { return }
            clearTransientStatus()
        }
    }

    /// Drop any transient message and restore the computed status line. Called on expiry, and
    /// directly when an alert is about to say the same thing better.
    func clearTransientStatus() {
        guard transientStatus != nil else { return }
        transientStatus = nil
        updateChrome()
    }

    /// How long a transient message holds the status line — long enough to read a short sentence,
    /// short enough that it never reads as the pane's permanent state.
    private static let transientStatusDuration: TimeInterval = 4

    /// The status line: a transient message when one is showing, else a selection summary when
    /// anything is marked, otherwise the item count, prefixed with the active type-to-filter. The
    /// synthetic `..` row is never counted — it isn't part of `panel`.
    private func statusText() -> String {
        if let transientStatus { return transientStatus }
        let total = panel.count
        let marked = panel.selectionCount
        let counts: String
        if marked > 0 {
            // A marked directory contributes its computed recursive size once sized
            // (Space-on-dir), otherwise zero — its inode size is noise, not content.
            let bytes = panel.selectedEntries.reduce(Int64(0)) { sum, entry in
                sum + panel.model.effectiveByteSize(of: entry)
            }
            counts = "\(marked) of \(total) selected · \(FileFormatting.byteString(bytes))"
        } else {
            counts = total == 1 ? "1 item" : "\(total) items"
        }

        // Say so whenever folder totals are filtered. Without this the mode is invisible in exactly
        // the situation that matters — a folder reading 2 GB where Finder says 17 GB — and the user
        // has no way to connect the number to the setting that produced it.
        let counted = areGitAwareSizesActive ? counts + " · sizes exclude Git-ignored" : counts

        let filter = panel.model.filter
        guard !filter.isEmpty else { return counted }
        // Cap the echoed filter: a normal type-to-filter is a few characters, but nothing stops a
        // long paste, and the status line reads "Filter “…” · N items" — an unbounded prefix would
        // crowd out the count. Keep the head, ellipsize the rest.
        let shown = filter.count > Self.maxFilterDisplayLength
            ? String(filter.prefix(Self.maxFilterDisplayLength)) + "…"
            : filter
        return "Filter “\(shown)” · \(counted)"
    }

    /// The longest type-to-filter string echoed verbatim in the status line before it's ellipsized.
    private static let maxFilterDisplayLength = 30

    func updateSortIndicators() {
        let sort = panel.model.sort
        for tableColumn in tableView.tableColumns {
            guard let column = Column(rawValue: tableColumn.identifier.rawValue) else { continue }
            let image: NSImage? = column.sortKey == sort.key
                ? NSImage(
                    named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
                )
                : nil
            tableView.setIndicatorImage(image, in: tableColumn)
        }
    }
}
