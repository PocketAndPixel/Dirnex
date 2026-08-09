import AppKit
import DirnexCore

/// Persisting a pane's tabs and bringing them back (PLAN.md §M1 "tabs per panel … restored on
/// relaunch"): what goes to disk on the way down, what is rebuilt from it at launch, and the
/// re-anchoring of the cursor and marks once a restored tab's directory has actually listed.
///
/// Everything here anchors by **identity, not row index** — the rule the live cursor already follows
/// across an FSEvents refresh — and identity is spelled as a path *relative to the tab's root*, the
/// same shape `expandedPaths` uses. That is what lets a tree tab (PLAN.md §M15) restore a cursor
/// sitting inside an expanded folder, which a bare leaf name could not address.
///
/// Split out of `PanelViewController+Tabs`, which was near SwiftLint's 500-line file limit, along
/// the seam the pane's other concerns already follow (`+Tree`, `+Render`, `+Columns`).
extension PanelViewController {
    // MARK: - Writing

    /// Write this pane's tabs (paths, per-tab sort, columns, the tree's expansion, and the
    /// cursor/marks) so they survive a relaunch. The cursor and marks are captured from the tab's own
    /// `Panel`, so an inactive tab persists exactly what the user last left in it. Cursor moves and
    /// mark toggles don't call this (a `UserDefaults` write per arrow key would be wasteful); the
    /// final position is instead captured on the way down via
    /// `BrowserWindowController.persistTabState`.
    func persistState() {
        guard let restorationKey else { return }
        // A tab standing in an unlocked vault is not written down (PLAN.md §M19 / `VaultPrivacy`).
        // Two reasons, and either would do: this file's own fields — the directory, the cursor's
        // file name, the marked names, the expanded folders — are a list of what is in the vault,
        // stored in the clear and outliving the lock; and a tab pointing into a volume that only
        // exists while unlocked cannot be restored anyway, which is the case `PersistedPane` already
        // falls back to Home for. Dropping every tab is therefore a legal state, not a hole.
        let kept = tabs.filter { !VaultMounts.shared.contains($0.panel.path) }
        let activeIndex = tabs.indices.contains(activeTabIndex)
            ? kept.firstIndex(where: { $0 === tabs[activeTabIndex] }) ?? 0
            : 0
        let persisted = kept.map { tab in
            PersistedTab(
                path: tab.panel.path,
                sort: tab.panel.model.sort,
                columns: tab.columnLayout,
                viewMode: tab.viewMode,
                expandedPaths: persistedExpandedPaths(for: tab),
                cursorPath: tab.cursorOnParentRow
                    ? nil
                    : tab.panel.currentEntry.map { restoreAnchor(for: $0.path, in: tab) },
                cursorOnParent: tab.cursorOnParentRow,
                markedPaths: tab.panel.selection.isEmpty
                    ? nil
                    : tab.panel.selection.map { restoreAnchor(for: $0, in: tab) }.sorted()
            )
        }
        TabPersistence.save(
            PersistedPane(tabs: persisted, activeIndex: activeIndex),
            paneKey: restorationKey
        )
    }

    /// How one entry is named on disk: its path relative to the tab's root — a bare leaf name for a
    /// row in the directory itself, `jMeter/results.zip` for one inside an expanded tree folder.
    /// Falls back to the leaf name for an entry that isn't under the root at all, which is every row
    /// of a *merged* or results listing (their entries carry their real, scattered `.local` paths);
    /// such a tab is never restored, so that value only has to be harmless.
    private func restoreAnchor(for path: VFSPath, in tab: PanelTab) -> String {
        rootRelativePath(path, under: tab.panel.path) ?? path.lastComponent
    }

    // MARK: - Re-applying on load

    /// Re-apply a restored tab's saved cursor and marks, resolving the persisted root-relative paths
    /// against the pane's root and matching them by identity against what it is drawing.
    ///
    /// Called at the root's first listing (from `navigate`) and **again as each restored tree
    /// expansion's own listing lands**: a cursor or a mark inside an expanded folder has no row to
    /// anchor on until that folder has been listed, so one pass at the root is not enough — that is
    /// the shape of the bug this exists for, a tree tab whose cursor sat on a nested file coming back
    /// with the cursor at the top.
    ///
    /// Whatever resolves is applied *and dropped from the pending state*, so a later pass can't yank
    /// a cursor the user has since moved or re-mark a row they unmarked; whatever never resolves is
    /// dropped once the last restored listing has landed (`finishRestoreTreeLoad`) — a file deleted
    /// since quit simply never matches, the same pruning a live refresh does. A tab that was never
    /// restored from disk has nothing pending and returns immediately. Called with
    /// `index == activeTabIndex`, so `panel`/`cursorOnParentRow` (which address the active tab) are
    /// this tab. Reports whether the cursor was anchored on this pass, so a caller rendering a tree
    /// landing can scroll to it.
    @discardableResult
    func applyPendingRestore(toTab index: Int) -> Bool {
        let tab = tabs[index]
        guard tab.hasPendingRestore else { return false }
        applyPendingMarks(of: tab)
        let anchored = applyPendingCursor(of: tab)
        // Nothing further is coming that could anchor the rest: drop it rather than leaving it to
        // land on whatever this tab is navigated to next.
        if tab.pendingRestoreTreeLoads == 0 { tab.clearPendingRestore() }
        return anchored
    }

    /// Re-mark what the pane can currently see, keeping the rest pending. `setSelection` intersects
    /// with the entries actually present, so a mark inside a folder that hasn't listed yet is simply
    /// not taken — and stays in the pending list for the pass that follows that folder's landing.
    private func applyPendingMarks(of tab: PanelTab) {
        guard let relatives = tab.pendingMarkPaths, !relatives.isEmpty else { return }
        let root = panel.path
        let wanted = relatives.map { (relative: $0, path: resolveRootRelative($0, under: root)) }
        panel.setSelection(panel.selection.union(wanted.map(\.path)))
        let unresolved = wanted.filter { !panel.selection.contains($0.path) }.map(\.relative)
        tab.pendingMarkPaths = unresolved.isEmpty ? nil : unresolved
    }

    /// Anchor the cursor if its row exists yet, reporting whether it moved.
    private func applyPendingCursor(of tab: PanelTab) -> Bool {
        if tab.pendingCursorOnParent, panel.parentPath != nil {
            cursorOnParentRow = true
            tab.pendingCursorOnParent = false
            return true
        }
        guard let relative = tab.pendingCursorPath,
              let row = panel.displayedIndex(ofID: resolveRootRelative(relative, under: panel.path))
        else { return false }
        panel.moveCursor(to: row)
        cursorOnParentRow = false
        tab.pendingCursorPath = nil
        return true
    }

    /// One restored expansion's listing has finished (landed, failed, or been overtaken by a
    /// navigation). When it was the last one the restore window closes, so anything still pending
    /// pointed at something that is no longer there and is dropped. Called from the tree's lazy
    /// loader, on every exit path — a folder that fails to list must not leave the window open.
    func finishRestoreTreeLoad(inTab index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        guard tab.pendingRestoreTreeLoads > 0 else { return }
        tab.pendingRestoreTreeLoads -= 1
        if tab.pendingRestoreTreeLoads == 0 { tab.clearPendingRestore() }
    }

    // MARK: - Reading from disk

    /// The tabs and active index a pane opens with, given its persisted state — what `init` installs.
    /// Wraps `restoredTabs` with the empty-fallback: when every persisted tab was dropped (a pane
    /// whose only tab was a remote FTP/SFTP/SMB folder is the common case — those can't be listed at
    /// launch without reconnecting), open a fresh tab at `defaultPath`, but carry the last-active
    /// tab's column layout forward. A dropped remote tab is still where the user set those widths, and
    /// a bare default layout snapped the Date column back to its default 150 on every relaunch of a
    /// pane whose only tab was remote — while a plain local folder, whose tab *is* restored, kept its
    /// widths, which is exactly the asymmetry that read as a bug.
    static func restoredLayout(
        from restoration: PersistedPane?,
        defaultPath: VFSPath,
        showHidden: Bool
    ) -> (tabs: [PanelTab], activeIndex: Int) {
        let restored = restoredTabs(from: restoration)
        guard !restored.isEmpty else {
            let fallback = PanelTab(
                path: defaultPath,
                showHidden: showHidden,
                columns: restoration?.activeTabColumns
            )
            return ([fallback], 0)
        }
        return (restored, min(max(restoration?.activeIndex ?? 0, 0), restored.count - 1))
    }

    /// Rebuild tabs from a persisted pane, dropping any whose directory has since
    /// vanished so a relaunch never opens onto a dead path or an error sheet.
    static func restoredTabs(from restoration: PersistedPane?) -> [PanelTab] {
        guard let restoration else { return [] }
        // Show-hidden is a single app-wide toggle, so every restored tab adopts it — the same
        // value a fresh tab gets. An in-session ⇧⌘. re-syncs them all live.
        let showHidden = AppPreferences.shared.showHidden
        return restoration.tabs.compactMap { persisted in
            let path = persisted.vfsPath
            var isDirectory: ObjCBool = false
            guard path.backend == .local,
                  FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            let tab = PanelTab(
                path: path,
                sort: persisted.fileSort,
                showHidden: showHidden,
                columns: persisted.columns
            )
            // The shape the tab was last left in (PLAN.md §M15) — restored, unlike the session-
            // scoped per-tab modes, because coming back to a tree as a flat list reads as loss.
            tab.viewMode = persisted.panelViewMode
            // …and the folders it had open, re-expanded lazily once its directory first lists.
            tab.pendingExpandedPaths = persisted.expandedPaths
            // Re-applied by `applyPendingRestore` once this tab's directory first lists (it isn't
            // listed yet — a restored tab loads lazily), by root-relative path so a since-deleted
            // file drops and a tree row inside an expanded folder is still addressable.
            tab.pendingCursorPath = persisted.cursorPath
            tab.pendingCursorOnParent = persisted.cursorOnParent ?? false
            tab.pendingMarkPaths = persisted.markedPaths
            return tab
        }
    }
}
