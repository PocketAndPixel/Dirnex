import AppKit
import DirnexCore

/// Tree view in a file pane (PLAN.md §M15 Slice 4): the inline-expanding list where folders open in
/// place and show their children indented. The whole design bet is that this is **not a second
/// surface** — it is the same `FileTableView` over the same `VFSPath` index space the flat list uses,
/// with `DirnexCore.TreeProjection` supplying the rows (the sidebar's shape, HISTORY.md §M8). So the
/// columns, the name cell's badges, marks, inline rename, drag/drop and the Quick View overlay keep
/// working unchanged; this file only adds the mode toggle, the expand/collapse keys, the lazy
/// per-level listing, and the one watcher over the whole expanded set.
///
/// The selection brain stays in the tested value type: `Panel` owns `tree`, the cursor, and the
/// marks, and every operation here mutates it and re-renders. Split into its own file for SwiftLint's
/// file-length limit, along the seam every other pane concern already follows.
extension PanelViewController {
    // MARK: - Per-tab state

    /// Which shape the active tab draws in — persisted, inherited by a spawned tab (the same way sort
    /// and columns are), and the source of truth `applyViewMode` keeps `panel.tree` in step with.
    var viewMode: PanelViewMode {
        get { tabs[activeTabIndex].viewMode }
        set { tabs[activeTabIndex].viewMode = newValue }
    }

    /// Whether a tree can apply to what is on screen — **everywhere**, which is a decision rather
    /// than the absence of one.
    ///
    /// This read `panel.path.backend == .local` until 2026-08-17, on the stated reasoning that a
    /// per-level lazy listing "needs a real directory to read". That is true of each *row*, and was
    /// never true of the pane's own path — which is what the gate was testing. The rows are what get
    /// expanded; `DirectoryLoader.list` goes through `CompositeBackend`, which routes per path; and
    /// `TreeProjection` recurses into each entry's **own** path, never assuming it descends from the
    /// root (its root level is just `listings[rootPath]`). So a merged iCloud row, a bucket, an SFTP
    /// directory and a folder inside an archive all expand through machinery that was already there,
    /// and the core needed no change to allow it.
    ///
    /// Kept as a named property with both of its readers — the toggle and the menu validator — rather
    /// than deleted along with the restriction: the day something genuinely cannot be a tree, the
    /// exclusion has to land in one place. One rule spelled twice is this codebase's most repeated
    /// bug (docs/NOTES.md ▸ Design lessons), and the checkmark-and-gray dead end this replaces was
    /// exactly that shape.
    var canUseTreeMode: Bool { true }

    // MARK: - Command (dispatched to the focused pane via the responder chain)

    /// View ▸ Tree View. Per tab like the size-viz mode, so one pane can be a tree while the other
    /// stays a list — the dual-pane payoff of comparing two shapes at once. Drives the tab directly.
    @objc func toggleTreeView(_ sender: Any?) {
        guard canUseTreeMode else { return }
        // The table's selection is the live cursor until its change notification fires a runloop pass
        // later; reconcile first so entering/leaving the tree anchors on the row the user is on.
        reconcileCursorFromTable()
        viewMode = (viewMode == .tree) ? .list : .tree
        applyViewMode()
        // Size bars carry into a tree, re-scoped per level (`SizeVisualization(tree:)`); this keeps
        // the column, projection and scan queue in step with the new shape, installing the column if
        // the mode is on, and renders.
        updateSizeVisualization()
        reloadEverything()
        startPaneWatcher(panel.path, force: true)
        persistState()
    }

    /// Bring `panel.tree` into agreement with the tab's `viewMode` and where it can apply — entering
    /// tree mode seeds the tree from the current directory, leaving it flattens back, both keeping the
    /// cursor on the same entry by identity (`Panel` does that). Idempotent, so a tab switched back to
    /// while already a tree is untouched. Called on the toggle and after every navigation; a
    /// navigation into an archive or a remote volume leaves tree mode without forgetting the
    /// preference, so walking back out to a local folder re-enters it.
    func applyViewMode() {
        if viewMode == .tree, canUseTreeMode {
            panel.enterTreeMode()
        } else {
            panel.exitTreeMode()
        }
    }

    // MARK: - Rendering one row's tree structure

    /// Apply this row's depth and disclosure state to its name cell, or reset a recycled cell back to
    /// the flat-list layout in list mode. Called per render from `PanelViewController+Table`. The
    /// disclosure toggle carries the row's own path, so clicking the triangle opens that folder
    /// without moving the cursor (Finder's behavior).
    func applyTreeLayout(to cell: FileCellView, entry: FileEntry, entryIndex index: Int) {
        guard let tree = panel.tree, tree.rows.indices.contains(index) else {
            cell.isTreeRow = false
            cell.activeTreeGuideLevel = nil
            cell.onDisclosureToggle = nil
            cell.applyTreeLayout()
            return
        }
        cell.isTreeRow = true
        cell.treeDepth = tree[index].depth
        cell.activeTreeGuideLevel = activeTreeGuideLevel(forEntryIndex: index)
        if entry.isDirectoryLike {
            cell.treeDisclosure = tree.isExpanded(entry.path) ? .expanded : .collapsed
            let path = entry.path
            cell.onDisclosureToggle = { [weak self] in self?.toggleTreeExpansion(for: path) }
        } else {
            cell.treeDisclosure = nil
            cell.onDisclosureToggle = nil
        }
        cell.applyTreeLayout()
    }

    // MARK: - Indent guides

    /// Re-derive which indent guide is the active one and, if it moved, repaint the rows on screen.
    ///
    /// The focus is the **pointer** while it is over this pane and the **cursor** otherwise. That
    /// order is the one thing here worth arguing: VS Code's guides are hover-driven because a tree
    /// there is a mouse surface, and this pane is not — a user arrowing through a tree would never
    /// see the highlight at all, so the cursor has to carry it. The pointer still wins while it is
    /// in the pane, which is what makes the guide answer the question the *hand* is asking.
    ///
    /// Called from `updateChrome`, the funnel every cursor move already goes through, and from the
    /// hover callback. Deriving it costs one scan of the rows, so it is done once here and read back
    /// per row from `tableView.activeTreeGuide` rather than recomputed in the render path.
    func updateTreeGuides() {
        let guide = treeGuideFocusIndex.flatMap { panel.tree?.activeGuide(forRow: $0) }
        guard guide != tableView.activeTreeGuide else { return }
        tableView.activeTreeGuide = guide
        repaintTreeGuides()
    }

    /// The row the active guide is derived from, as a `panel` entry index — the hovered row when the
    /// pointer is over a real one, else the cursor. `nil` on `..` (hovered or the cursor), which is
    /// not an entry and belongs to no folder in the tree.
    private var treeGuideFocusIndex: Int? {
        if let hovered = entryIndex(forRow: tableView.hoveredRow) { return hovered }
        return cursorOnParentRow ? nil : panel.cursor
    }

    /// The guide level entry `index` should draw as the active one, or `nil` — read per row by
    /// `applyTreeLayout(to:entry:entryIndex:)`, so a cell built while scrolling arrives correct.
    func activeTreeGuideLevel(forEntryIndex index: Int) -> Int? {
        guard let guide = tableView.activeTreeGuide, guide.rows.contains(index) else { return nil }
        return guide.level
    }

    /// Push the new active level onto the name cells already on screen. A `reloadData` would do it
    /// too and is far too much for a pointer moving one row: the cursor row's editor, the scroll
    /// position and every badge would be rebuilt to change the color of one hairline.
    ///
    /// Reaches the cell through the row view's own subviews rather than `view(atColumn:row:)`, which
    /// was measured to answer `nil` for a freshly built row (`FileTableView.disclosureCell`).
    private func repaintTreeGuides() {
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.lowerBound..<rows.upperBound {
            guard let rowView = tableView.rowView(atRow: row, makeIfNecessary: false) else { continue }
            let level = entryIndex(forRow: row).flatMap(activeTreeGuideLevel(forEntryIndex:))
            for case let cell as FileCellView in rowView.subviews where cell.isNameCell {
                cell.activeTreeGuideLevel = level
            }
        }
    }

    // MARK: - Keys (→ expand / step in, ← collapse / step out)

    /// →: open a closed folder, or step into an already-open one (the sidebar's vocabulary,
    /// `SidebarViewController+Keyboard`). Returns `false` in list mode so the arrow falls through to
    /// the table unchanged; `true` in a tree, whether or not anything moved — the arrows belong to
    /// the tree there.
    func fileTableExpandOrStepIn(_ tableView: FileTableView) -> Bool {
        guard let tree = panel.tree else { return false }
        reconcileCursorFromTable()
        guard let entry = panel.currentEntry, entry.isDirectoryLike else { return true }
        if tree.isExpanded(entry.path) {
            stepIntoExpandedFolder()
        } else {
            expandFolder(entry.path)
        }
        return true
    }

    /// ←: close an open folder, or step out to its parent folder's row. Same `false`/`true` contract
    /// as `fileTableExpandOrStepIn`.
    func fileTableCollapseOrStepOut(_ tableView: FileTableView) -> Bool {
        guard let tree = panel.tree else { return false }
        reconcileCursorFromTable()
        guard let entry = panel.currentEntry else { return true }
        if entry.isDirectoryLike, tree.isExpanded(entry.path) {
            collapseFolder(entry.path)
        } else {
            stepOutToParent()
        }
        return true
    }

    /// Toggle a specific folder's expansion — the disclosure-triangle click. Keyed by path rather
    /// than the cursor so the click never moves the cursor.
    func toggleTreeExpansion(for path: VFSPath) {
        guard let tree = panel.tree else { return }
        reconcileCursorFromTable()
        if tree.isExpanded(path) {
            collapseFolder(path)
        } else {
            expandFolder(path)
        }
    }

    private func expandFolder(_ path: VFSPath) {
        panel.expand(path)
        // List the children the first time it opens; a folder re-opened after a collapse still holds
        // its listing, so it renders instantly.
        if panel.tree?.hasListing(for: path) == false {
            loadTreeChild(path)
        }
        renderTreeChange()
        persistState()
    }

    private func collapseFolder(_ path: VFSPath) {
        panel.collapse(path)
        renderTreeChange()
        persistState()
    }

    /// Move the cursor onto the first child of the open folder under it. A no-op when the folder is
    /// open but empty (or every child filtered out), whose next row is a sibling at the same depth.
    private func stepIntoExpandedFolder() {
        guard let tree = panel.tree else { return }
        let here = tree[panel.cursor].depth
        let next = panel.cursor + 1
        guard tree.rows.indices.contains(next), tree[next].depth > here else { return }
        moveTreeCursor(toEntryIndex: next)
    }

    /// Climb from a row to its parent folder's row, the way ← walks up an outline view. A no-op at
    /// depth 0, whose parent is the tree root and has no row.
    ///
    /// Answered from the **rows** — the nearest shallower one above the cursor — rather than by
    /// looking up `entry.path.parent`, which is the same answer everywhere a child's path descends
    /// from its parent's and no answer at all where it does not: a bucket's contents are on the
    /// bucket's own backend, so the parent of `s3://bucket/docs` is `s3://bucket/`, and the row above
    /// it is `s3account:/bucket`. Depth is what the tree actually draws, so it cannot disagree with
    /// what ← looks like it should do.
    private func stepOutToParent() {
        guard let tree = panel.tree, tree.rows.indices.contains(panel.cursor) else { return }
        let depth = tree[panel.cursor].depth
        guard depth > 0,
              let parentRow = tree.rows[..<panel.cursor].lastIndex(where: { $0.depth < depth })
        else { return }
        moveTreeCursor(toEntryIndex: parentRow)
    }

    private func moveTreeCursor(toEntryIndex index: Int) {
        panel.moveCursor(to: index)
        syncCursorToTable(scroll: true)
        updateChrome()
        refreshQuickLookIfVisible()
    }

    /// Re-render after a tree mutation (expand / collapse / a child load) without yanking the scroll
    /// position, and re-point the watcher at the new set of listed directories. Keeps the tree
    /// refresh tail NOTES.md records — `reloadData` → `syncCursorToTable(scroll: false)`.
    private func renderTreeChange() {
        renderRefresh()
        startWatchingTree()
    }

    // MARK: - Lazy per-level listing

    /// List `path`'s children off the main thread and install them in the tree — its lazy load on
    /// expand or on restore. Guarded on `loadToken` so a navigation that lands first wins, and on the
    /// pane still being this tree. A folder that fails to list (deleted, unreadable) stays childless.
    ///
    /// `duringRestore` marks a load kicked off by `restorePendingTreeExpansion`: the rows it brings in
    /// are the ones a restored cursor or mark may be waiting on, so the landing re-runs
    /// `applyPendingRestore` (scrolling to the cursor when this is the level that carried it), and
    /// every exit path reports back so the restore window closes even when the folder never listed.
    private func loadTreeChild(_ path: VFSPath, duringRestore: Bool = false) {
        let token = loadToken
        let root = panel.path
        let tabIndex = activeTabIndex
        Task {
            defer { if duringRestore { finishRestoreTreeLoad(inTab: tabIndex) } }
            guard let entries = await treeChildEntries(at: path) else { return }
            guard token == loadToken, panel.isTree, panel.path == root else { return }
            if deferRefreshIfRenaming() { return }
            reconcileCursorFromTable()
            panel.setTreeChildListing(path, entries: entries)
            var anchoredCursor = false
            if duringRestore { anchoredCursor = applyPendingRestore(toTab: tabIndex) }
            renderTreeChange()
            // `renderTreeChange` deliberately doesn't scroll (it is the live-refresh render); a cursor
            // the user last left deep in the tree has to be brought into view, as a navigation would.
            if anchoredCursor { syncCursorToTable(scroll: true) }
            persistState()
        }
    }

    /// What to draw beneath an expanded row — and what a refresh re-reads it with: ordinarily one
    /// listing, and for a **bucket row in an S3 account pane** a connection, since
    /// `S3AccountBackend` answers for its root and nothing deeper. See `s3BucketChildren(at:)` for
    /// why that is a crossing rather than a walk, and why its rows keep their own `s3://` paths.
    ///
    /// `nil` for anything that failed to list — the folder stays childless, as an unreadable or
    /// deleted one does.
    func treeChildEntries(at path: VFSPath) async -> [FileEntry]? {
        if path.isS3BucketRow {
            return await s3BucketChildren(at: path)
        }
        return try? await DirectoryLoader.list(backend, at: path).entries
    }

    // MARK: - Expansion persistence

    /// A tab's expanded tree folders as paths relative to its root, for `PersistedTab` — `nil` in
    /// list mode or an all-collapsed tree, so the common case stays out of the JSON. Directory-
    /// relative and sorted for a stable on-disk form, the same anchoring the cursor and marks use.
    /// Takes the tab (not the active `panel`) so `persistState` can capture every tab, active or not.
    func persistedExpandedPaths(for tab: PanelTab) -> [String]? {
        guard let expanded = tab.panel.tree?.expanded, !expanded.isEmpty else { return nil }
        let root = tab.panel.path
        let relative = expanded.compactMap { rootRelativePath($0, under: root) }.sorted()
        return relative.isEmpty ? nil : relative
    }

    /// Re-expand and lazily re-list the folders a restored tree had open (PLAN.md §M15 "relaunch
    /// restores the expansion"). One-shot: the pending list is cleared after, so a later navigation
    /// in the tab starts collapsed. Runs after the root's first load, inside `navigate` — and
    /// *before* the cursor/marks are re-applied, so the count of listings still to come is armed
    /// before the first pass at them: each one that lands is another chance to anchor a row that
    /// lives inside one of these folders, and the last one closes the restore window
    /// (`finishRestoreTreeLoad`).
    func restorePendingTreeExpansion() {
        let tab = tabs[activeTabIndex]
        guard let relatives = tab.pendingExpandedPaths, !relatives.isEmpty else { return }
        tab.pendingExpandedPaths = nil
        guard panel.isTree else { return }
        let root = panel.path
        tab.pendingRestoreTreeLoads = relatives.count
        for relative in relatives {
            let path = resolveRootRelative(relative, under: root)
            panel.expand(path)
            loadTreeChild(path, duringRestore: true)
        }
        renderTreeChange()
    }

    /// `path` (a descendant of `root`) as a `/`-joined path relative to it, or `nil` if it is the
    /// root itself or not under it. Internal because the tab's persisted cursor and marks are spelled
    /// the same way (`PanelViewController+Restore`) — one anchoring for everything a tab restores.
    func rootRelativePath(_ path: VFSPath, under root: VFSPath) -> String? {
        guard path != root, path.isSelfOrDescendant(of: root) else { return nil }
        let base = root.isRoot ? "" : root.path
        let relative = String(path.path.dropFirst(base.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return relative.isEmpty ? nil : relative
    }

    /// The inverse: resolve a stored relative path back to an absolute one under `root`, component by
    /// component so a leading slash or an empty segment can't confuse it. Internal for the same
    /// reason as `rootRelativePath`.
    func resolveRootRelative(_ relative: String, under root: VFSPath) -> VFSPath {
        relative.split(separator: "/").reduce(root) { $0.appending(String($1)) }
    }
}
