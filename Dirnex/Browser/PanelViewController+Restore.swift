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
        let kept = tabs.filter { isWorthPersisting($0) }
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
                    : tab.panel.selection.map { restoreAnchor(for: $0, in: tab) }.sorted(),
                endpoint: reconnectEndpoint(for: tab),
                history: persistedHistory(for: tab)
            )
        }
        TabPersistence.save(
            PersistedPane(tabs: persisted, activeIndex: activeIndex),
            paneKey: restorationKey,
            to: tabStateDefaults
        )
    }

    /// Whether this tab is one to write down at all.
    ///
    /// Two exclusions, and they are exclusions for opposite reasons. A tab standing in an **unlocked
    /// vault** is withheld on privacy grounds (PLAN.md §M19 / `VaultPrivacy`): this file's own fields
    /// — the directory, the cursor's file name, the marked names, the expanded folders — are a list
    /// of what is in the vault, stored in the clear and outliving the lock; and a tab pointing into a
    /// volume that only exists while unlocked could not be restored anyway. Dropping every tab is
    /// therefore a legal state, not a hole.
    ///
    /// A tab inside a **nested archive** is withheld because it cannot come back: its "archive" is a
    /// temp extraction of a member of the enclosing archive, so the file its backend names is gone by
    /// the next launch — and the registry that knows it came out of somewhere else is session-scoped,
    /// so a temp file that happened to survive would browse as a top-level archive with a broken way
    /// out. Refused here rather than at the restore, where the only evidence left is a path under
    /// `NSTemporaryDirectory()` — which is a guess, not a fact.
    private func isWorthPersisting(_ tab: PanelTab) -> Bool {
        isWorthPersisting(tab.panel.path)
    }

    /// The same two exclusions for one place, which is what a tab's trail asks of each entry: a
    /// folder in a vault is as much a list of what is in it when it sits in ⌘['s list as when a tab
    /// is standing in it, and a nested archive's temp extraction is as gone by the next launch.
    private func isWorthPersisting(_ path: VFSPath) -> Bool {
        guard !VaultMounts.shared.contains(path) else { return false }
        guard let archivePath = path.backend.archivePath else { return true }
        return !(host?.nestedArchiveRegistry.isNestedMount(archivePath) ?? false)
    }

    /// The tab's back/forward trail as it is written down, or `nil` when there is nothing worth
    /// writing. The core decides what is left out (`NavigationHistory.stored`); this supplies the two
    /// facts only the app has: which places it must not keep, and how to reconnect each server the
    /// trail visits — the live connection first, as for the tab itself, then whatever the tab's
    /// restored trail carried, so a trail that came back and was never walked is written back whole.
    private func persistedHistory(for tab: PanelTab) -> StoredNavigationHistory? {
        let composite = backend as? CompositeBackend
        return tab.history.stored(
            at: tab.panel.path,
            endpoint: { composite?.endpoint(for: $0) ?? tab.endpoint(for: $0) },
            isExcluded: { !isWorthPersisting($0) }
        )
    }

    /// Where this tab would have to reconnect to list again, for a tab on a connected account.
    ///
    /// Asked of the pane's own `CompositeBackend`, which is the one thing that knows what a live
    /// connection was *made with* — a `VFSBackendID` carries the descriptor and not the auth method.
    /// The fallback to the tab's own pending endpoint is what keeps an inactive restored tab from
    /// being lost on the second quit: it has never been activated, so nothing has registered a
    /// connection for it, and reading only the composite would write it back down with no way home.
    func reconnectEndpoint(for tab: PanelTab) -> ServerEndpoint? {
        guard tab.panel.path.backend.isRemoteConnection else { return nil }
        let live = (backend as? CompositeBackend)?.endpoint(for: tab.panel.path.backend)
        return live ?? tab.endpoint(for: tab.panel.path.backend)
    }

    /// How one entry is named on disk: its path relative to the tab's root — a bare leaf name for a
    /// row in the directory itself, `jMeter/Synergie.zip` for one inside an expanded tree folder.
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
    /// A walk along the trail (⌘[, ⌘], the ⌥↓ list) seeds the same pending cursor to put the pane back
    /// where it was left in the folder (`preparePendingRestore`), and is re-applied the same way.
    ///
    /// Called at the root's listing (from `navigate`) and **again as each restored tree
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
    /// whose only tab was a remote FTP/SFTP/SMB/S3 folder is the common case — those can't be listed
    /// at launch without reconnecting), open a fresh tab at `defaultPath`, but carry the last-active
    /// tab's **column layout, view mode and sort** forward. A dropped remote tab is still where the
    /// user set those, and a bare default snapped the Date column back to its default 150 on every
    /// relaunch of a pane whose only tab was remote — while a plain local folder, whose tab *is*
    /// restored, kept its widths, which is exactly the asymmetry that read as a bug. The tree/list
    /// shape and the sort are the same asymmetry in the two other fields a dropped tab carries, both
    /// reported 2026-08-20 against an S3 account: a pane set to a tree came back a flat list, and one
    /// set to newest-first came back sorted by name. See `PersistedPane`'s three `activeTab…`
    /// properties; anything a fourth field ever adds belongs beside them.
    static func restoredLayout(
        from restoration: PersistedPane?,
        defaultPath: VFSPath,
        showHidden: Bool
    ) -> (tabs: [PanelTab], activeIndex: Int) {
        let restored = restoredTabs(from: restoration)
        guard !restored.isEmpty else {
            let fallback = PanelTab(
                path: defaultPath,
                sort: restoration?.activeTabSort ?? .default,
                showHidden: showHidden,
                columns: restoration?.activeTabColumns
            )
            // …and the shape it was drawing in, for the same reason and with the same asymmetry
            // behind it: a pane set to a tree and then pointed at S3 came back a flat list, while a
            // pane whose tab *was* restored kept its tree. The mode is per tab, so the honest thing
            // to carry onto a stand-in tab is what the tab it stands in for was last drawing.
            fallback.viewMode = restoration?.activeTabViewMode ?? .list
            return ([fallback], 0)
        }
        return (restored, min(max(restoration?.activeIndex ?? 0, 0), restored.count - 1))
    }

    /// Rebuild tabs from a persisted pane, dropping any whose *place* no longer exists so a relaunch
    /// never opens onto a dead path or an error sheet.
    ///
    /// It used to keep only the tabs it could list with no preparation — `.local`, and the directory
    /// still there — which meant a browsed `.zip` and every connected server were dropped: quit with
    /// four bucket tabs open and they were gone, while the saved connection sat in the sidebar
    /// (docs/LOCATION-SUPPORT.md ▸ "Session restore and workspaces drop remote tabs"). What decides
    /// now is `TabRestorePolicy`, which answers what each tab *needs* — a directory, an archive file,
    /// or a connection — and this supplies the one thing a pure rule cannot: whether the disk agrees.
    /// A connection is not established here; it is recorded on the tab and opened by the navigation
    /// that first wants it (`PanelViewController+Reconnect`), so a pane restoring five server tabs
    /// contacts nothing until one of them is on screen.
    static func restoredTabs(from restoration: PersistedPane?) -> [PanelTab] {
        guard let restoration else { return [] }
        // Show-hidden is a single app-wide toggle, so every restored tab adopts it — the same
        // value a fresh tab gets. An in-session ⇧⌘. re-syncs them all live.
        let showHidden = AppPreferences.shared.showHidden
        return restoration.tabs.compactMap { persisted in
            let path = persisted.vfsPath
            guard let requirement = TabRestorePolicy.requirement(
                for: path,
                endpoint: persisted.serverEndpoint
            ), canRestore(requirement, at: path) else { return nil }
            let tab = PanelTab(
                path: path,
                sort: persisted.fileSort,
                showHidden: showHidden,
                columns: persisted.columns
            )
            // Recorded, never opened: the first navigation into this tab registers it, and only if
            // somebody is asking (`RemoteRefreshPolicy.contactsServersUnasked`).
            if case let .connection(endpoint) = requirement { tab.pendingConnection = endpoint }
            // Where it had been, and how to reconnect to each server on the way. Nothing is checked
            // on disk: a folder deleted since quit is skipped when ⌘[ reaches it.
            tab.history = NavigationHistory(restoring: persisted.history, at: path)
            for server in persisted.history?.serverEndpoints ?? [] {
                guard let id = server.backendID else { continue }
                tab.trailEndpoints[id] = server
            }
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

    /// Whether the disk agrees with what `requirement` asks for — the impure half of the decision,
    /// kept apart from the rule so the rule stays a pure value the core can test.
    ///
    /// The archive case checks a **different path** from the tab's own, and that is the whole point
    /// of the requirement carrying one: a tab three folders into a zip has a path (`/docs/api`) that
    /// exists nowhere, so stat-ing the tab's path would drop every archive tab but a root's. It must
    /// also be a *file* — a directory sitting where an archive used to be is not one, and mounting it
    /// would spawn `bsdtar` at launch to learn that.
    ///
    /// A connection asks the disk nothing. Whether the server answers is the listing's question, and
    /// it is not one that can be settled without contacting it — which is exactly what a restore has
    /// not been asked to do yet.
    static func canRestore(_ requirement: TabRestoreRequirement, at path: VFSPath) -> Bool {
        var isDirectory: ObjCBool = false
        switch requirement {
        case .directoryOnDisk:
            let exists = FileManager.default.fileExists(
                atPath: path.path,
                isDirectory: &isDirectory
            )
            return exists && isDirectory.boolValue
        case let .archiveOnDisk(archive):
            let exists = FileManager.default.fileExists(atPath: archive, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        case .connection:
            return true
        // Nothing on disk to check and nothing to connect; whether access is still granted is the
        // listing's question (PLAN.md §M28).
        case .photosLibrary:
            return true
        }
    }
}
