import AppKit
import DirnexCore

/// Opening entries and walking the directory tree: the small navigation actions the
/// key model, double-click, and the `..` row funnel into. Kept out of the main
/// controller so it stays under SwiftLint's file/type-body limits (like `+Table`,
/// `+Chrome`, `+ParentRow`).
extension PanelViewController {
    /// Enter the directory under the cursor, browse into an archive file, or launch a plain
    /// file with its default app.
    func openCurrentEntry() {
        guard let entry = panel.currentEntry else { return }
        if let target = panel.openTarget(for: entry) {
            // A folder opened from a results tab must not replace the results in place — route it
            // elsewhere so the listing survives (PLAN.md §M4 search, §M8 Recents and Trash).
            if isResultsListing {
                openResultDirectory(target)
            } else {
                navigate(to: target)
            }
        } else if entry.path.backend == .local, ArchiveType.isBrowsable(entry.name) {
            // A local archive file — browse into its virtual folder tree instead of launching.
            navigate(to: archiveRoot(for: entry))
        } else if entry.path.backend.isArchive, ArchiveType.isBrowsable(entry.name) {
            // A nested archive — extract this member to disk and browse into it (PLAN.md §M4).
            beginNestedArchiveEntry(for: entry)
        } else if entry.path.backend == .local {
            NSWorkspace.shared.open(entry.path.localURL)
        }
        // Any other non-directory entry inside an archive (a plain file member) can't be launched
        // in place, so it's a no-op rather than opening a meaningless local URL.
    }

    /// Open a directory picked from a results tab (search hits, Recents, or the Trash). The listing
    /// is what the user is browsing, so opening one of its folders never overwrites this tab: it
    /// lands in the **other** pane as a new tab (the "found it here, go look at it there" flow), or —
    /// when the window has no counterpart pane — as a new tab beside the results in this one.
    ///
    /// The `focusOpenedSearchDirectory` preference (default off) decides whether focus follows the
    /// opened folder or stays on the results so more hits can be opened in turn.
    private func openResultDirectory(_ target: VFSPath) {
        let focusFollows = AppPreferences.shared.focusOpenedSearchDirectory
        if let destination = host?.panelCounterpart(of: self) {
            // Always show the folder in the other pane; only move window focus there on request.
            destination.openInNewTab(target)
            if focusFollows {
                host?.panelRequestsFocusSwitch(self)
            }
        } else {
            // Single-pane: open beside the results here, switching to it only if focus should follow.
            openInNewTab(target, activate: focusFollows)
        }
    }

    /// Walk up one level, landing the cursor on the directory we came from. Inside an archive
    /// this walks the inner tree and, at the archive root, exits to the containing folder. A
    /// no-op on a virtual results pane — its synthetic parent isn't a browsable directory.
    func goToParent() {
        if isArchive {
            _ = goUpWithinArchive()
            return
        }
        guard panel.path.backend == .local else { return }
        let current = panel.path
        guard let parent = panel.parentPath else { return }
        navigate(to: parent, focus: current)
    }

    /// Double-click: go up on the `..` row, otherwise open the clicked entry.
    @objc func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        if isParentRow(row) {
            goToParent()
            return
        }
        guard let index = entryIndex(forRow: row) else { return }
        panel.moveCursor(to: index)
        openCurrentEntry()
    }
}
