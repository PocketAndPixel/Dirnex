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
            //
            // The merged iCloud listing is the exception, and it is the same one that makes it
            // navigate in place to begin with (PLAN.md §M9): it is a *place*, not a set of hits, so
            // stepping into "Pages" should walk this pane into that folder the way stepping into any
            // folder does. Sending it to the other pane — which is right for a search you want to
            // keep — reads as the click going to the wrong window.
            if isResultsListing, !isICloudListing {
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
            // An evicted iCloud item has a real name and a real size and no bytes, so handing it
            // straight to `NSWorkspace` doesn't fail — it blocks whichever app opens it, silently,
            // for as long as the download takes (PLAN.md §M9). Fetch it first, visibly.
            CloudDownloadPrompt.materialize(entry, using: backend, over: view.window) { [weak self] in
                NSWorkspace.shared.open(entry.path.localURL)
                // The badge that said "not downloaded" is now wrong. A real directory hears about
                // the materialization from its watcher; the merged iCloud listing has none, so it
                // re-gathers here or the arrow stays on a file that is fully local.
                if entry.isDataless, self?.isICloudListing == true {
                    self?.refreshCurrentDirectory(selecting: entry.path)
                }
            }
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
        // Up out of iCloud Drive is the merged listing, not the container machinery that holds it:
        // the real parent of an app library's `Documents` is a one-child folder nobody asked to see,
        // and the real parent of a loose folder like "Car" is the CloudDocs container, which *is*
        // iCloud Drive as far as the listing is concerned (PLAN.md §M9). The cursor lands on the row
        // we came out of, as it does walking up anywhere.
        if ICloudDrive.walksUpToMerge(from: current) {
            showICloudDrive(selecting: current)
            return
        }
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
