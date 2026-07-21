import AppKit
import DirnexCore

/// Size-visualization mode in a file pane: the ncdu-style bar column, and the scan that fills it
/// (PLAN.md §M6 "Size visualization mode: toggle panel to ncdu-style bars, computed async, cached").
/// The pane owns *when* to look; `DirectorySizeProvider` owns the walking and the cache, and
/// `DirnexCore`'s `SizeVisualization` owns what the bytes mean — so this file only keeps the column,
/// the projection and the scan queue in step with the directory on screen.
///
/// **The mode is per tab**, not an app-wide preference like Show Tags. Two reasons, and the second is
/// the deciding one: it is what "toggle *panel* to ncdu-style bars" says, and it is the dual-pane
/// payoff — bars in one pane while the other browses normally. But mainly, this mode is the only one
/// in the app that *spends* something to be on. An app-wide flag would set every open tab walking at
/// once, and the measured cost of walking one `~` is ~16 s of eight-wide background I/O.
///
/// **Auto-scan, ncdu's model** (the policy question pass 9 raised, settled by the user): switching
/// the mode on queues every unsized directory child immediately, rather than waiting for the user to
/// press Space on each. The alternative was never really available — the core's rule is that an
/// unwalked directory has *no* bar rather than a zero one, so a lazy mode would open on a column
/// that is empty for every folder in it, which is not a visualization of anything.
extension PanelViewController {
    // MARK: - Per-tab state

    /// Whether this tab is in size-visualization mode. UI-only and session-scoped, like
    /// `cursorOnParentRow` and the Git/tag snapshots beside it.
    var isSizeVisualizationEnabled: Bool {
        get { tabs[activeTabIndex].isSizeVisualizationEnabled }
        set { tabs[activeTabIndex].isSizeVisualizationEnabled = newValue }
    }

    /// The projection the active tab's bars are drawn from, rebuilt once per render pass.
    ///
    /// Held rather than recomputed per row because `bar(for:)` is O(1) only *given* the projection —
    /// building it is O(n), and the table asks once per visible row per column. Rebuilding it per row
    /// would make a render O(n²).
    var sizeVisualization: SizeVisualization? {
        get { tabs[activeTabIndex].sizeVisualization }
        set { tabs[activeTabIndex].sizeVisualization = newValue }
    }

    /// Whether bars belong on these rows: the tab wants them, **and** these rows can be walked at
    /// all. The second half is not the toggle being second-guessed — a `.search` results pane is a
    /// synthetic listing whose rows live in a dozen different folders, so "share of this directory"
    /// has no referent, and an archive's or SFTP's tree costs a network round trip per level.
    var areSizeBarsVisible: Bool {
        isSizeVisualizationEnabled && panel.path.backend == .local && !isResultsListing
    }

    // MARK: - .gitignore-aware totals

    /// Whether this tab's folder totals are asked to leave out what Git ignores.
    var isGitAwareSizesEnabled: Bool {
        get { tabs[activeTabIndex].isGitAwareSizesEnabled }
        set { tabs[activeTabIndex].isGitAwareSizesEnabled = newValue }
    }

    /// Whether that setting is actually in force for the directory on screen — it needs a repository
    /// and a snapshot to say what is ignored, and outside one there is nothing to exclude. Kept
    /// separate from the flag itself for the reason the tag and sync-status toggles are: browsing out
    /// of a repository suppresses the filtering, and that is not the user having switched it off.
    ///
    /// It also drives the status line, which is not decoration. A folder reading 2 GB when Finder
    /// says 17 GB, with nothing on screen explaining why, is worse than not having the feature.
    var areGitAwareSizesActive: Bool {
        isGitAwareSizesEnabled && panel.path.backend == .local && gitSnapshot != nil
    }

    /// How every total this pane asks for is counted. The rule carries the snapshot itself, so a
    /// walk holds the ignore rules as they were when it started rather than reaching back to a pane
    /// that may have navigated on.
    var directorySizeRule: DirectorySizeRule {
        guard areGitAwareSizesActive, let gitSnapshot else { return .everything }
        return .gitAware(gitSnapshot)
    }

    /// Adopt a changed rule: every total on screen was counted under the old one, so it answers a
    /// question nobody is asking any more — drop it, then re-seed from whatever the cache already
    /// knows under the new scope and walk the rest.
    ///
    /// Called on the toggle, and on entering or leaving a repository while the toggle is on. **Not**
    /// on every snapshot change: a save flips a file to `M` without moving a single ignore rule, and
    /// re-walking the tree on each keystroke-to-disk is exactly the thrash
    /// `DirectorySizeProvider.gitStatusDidChange` exists to avoid. The rules genuinely changing
    /// arrives as its own notification.
    func directorySizeRuleDidChange() {
        if deferRefreshIfRenaming() { return }
        reconcileCursorFromTable()
        panel.clearDirectorySizes()
        // In the mode, this seeds, re-renders and re-queues the walks; outside it, the size column
        // still has to be repainted from nothing, and Space-on-dir will re-size on demand.
        if areSizeBarsVisible {
            updateSizeVisualization()
        } else {
            renderRefresh()
        }
    }

    // MARK: - Command (dispatched to the focused pane via the responder chain)

    /// View ▸ Size Visualization. Per pane and tab, so — unlike Show Tags — this drives the tab
    /// directly rather than a shared preference.
    @objc func toggleSizeVisualization(_ sender: Any?) {
        isSizeVisualizationEnabled.toggle()
        updateSizeVisualization()
    }

    /// View ▸ Exclude Git-Ignored from Sizes. Per tab like the mode above, and independent of it:
    /// it filters the size *column* too, so Space-on-dir sizing obeys it with the bars switched off.
    @objc func toggleGitAwareSizes(_ sender: Any?) {
        isGitAwareSizesEnabled.toggle()
        directorySizeRuleDidChange()
    }

    // MARK: - Keeping up to date

    func observeDirectorySizeChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(directorySizesDidChange),
            name: DirectorySizeProvider.didChangeNotification,
            object: nil
        )
    }

    /// Totals landed for a directory this pane may be showing. Ignore every other one — with two
    /// panes and several tabs, most notifications are somebody else's.
    ///
    /// The match is `isSelfOrDescendant` in both directions rather than `==`, because this fires for
    /// invalidation as well as for scan results: an FSEvents ping deep under the folder on screen
    /// invalidates this folder's line, and the notification carries the *event's* path, not ours.
    @objc private func directorySizesDidChange(_ notification: Notification) {
        guard let directory = notification.userInfo?[DirectorySizeProvider.directoryKey] as? VFSPath,
              directory.isSelfOrDescendant(of: panel.path) || panel.path.isSelfOrDescendant(
                  of: directory
              )
        else { return }
        // The repository's ignore rules moved (a `.gitignore` edit, a branch switch). What this pane
        // is showing is not stale but *wrong*, and it is wrong whether or not the bars are on, since
        // the size column carries the same filtered totals. Same path as the toggle: drop, re-seed,
        // re-walk.
        let rulesChanged = notification.userInfo?[
            DirectorySizeProvider.rulesChangedKey
        ] as? Bool ?? false
        if rulesChanged {
            guard areGitAwareSizesActive else { return }
            directorySizeRuleDidChange()
            return
        }
        guard areSizeBarsVisible else { return }
        // A rename in progress owns the table; the end-editing handler replays what it skipped.
        if deferRefreshIfRenaming() { return }
        guard apply(notification) || seedFromCache() else { return }
        // A size can reorder the list when sorting by size, so this is a real re-render — but the
        // background kind that never scrolls: bars arriving must not yank the user's reading spot.
        renderRefresh()
    }

    /// Take the totals a publish delivered, reporting whether any of them were news.
    ///
    /// **The payload is the authoritative path; the cache is only the fallback.** A publish announces
    /// walks that have already finished, and between their landing and this notification the cache
    /// can have been emptied by any pane's FSEvents watcher — measured live, a pane sitting on `~`
    /// invalidates every descendant total several times a second, which lost five of nine freshly
    /// walked folders and left them permanently blank. What was computed arrives here directly, so
    /// that race cannot cost a number any more.
    ///
    /// Totals counted under a scope this pane is not showing are dropped: the other pane may be
    /// sizing the same folder git-aware while this one wants everything, and the two answers are not
    /// interchangeable.
    private func apply(_ notification: Notification) -> Bool {
        guard let totals = notification.userInfo?[
            DirectorySizeProvider.totalsKey
        ] as? [VFSPath: Int64],
            let scope = notification.userInfo?[DirectorySizeProvider.scopeKey]
            as? DirectorySizeScope,
            scope == directorySizeRule.scope
        else { return false }
        let fresh = totals.filter { panel.model.directorySizes[$0.key] != $0.value }
        guard !fresh.isEmpty else { return false }
        reconcileCursorFromTable()
        panel.setDirectorySizes(fresh)
        return true
    }

    /// Re-derive the active tab's bars for the directory now on screen: install or remove the column,
    /// seed whatever the cache already knows, and queue the rest. Called on navigation, on a tab
    /// switch, on every live refresh, and when the mode is toggled.
    func updateSizeVisualization() {
        guard areSizeBarsVisible else {
            clearSizeVisualization()
            return
        }
        updateSizeBarColumn()
        if deferRefreshIfRenaming() { return }
        // Seed before rendering: the cache is what makes bars appear *with* the folder on a revisit
        // rather than after it, and seeding also shrinks the scan queue below to what is genuinely
        // unknown. Stale-while-revalidate — a seeded total is corrected by the FSEvents
        // invalidation that any real change triggers.
        seedFromCache()
        // **Unconditionally**, even when the seed found nothing — this render is what builds the
        // projection (`rebuildSizeVisualization`), and the projection is what both draws the bars
        // and queues the walks. Skipping it when the cache is cold, which is exactly the state of a
        // first toggle, left the mode installing its column and then doing nothing at all: no bars,
        // no scan, because the pending list is read *from* the projection that was never built.
        renderRefresh()
    }

    /// Apply everything the shared cache already knows about these rows, in **one** bulk call,
    /// reporting whether anything actually changed.
    ///
    /// Never `setDirectorySize` per row: pass 9 measured that path re-sorting the whole listing on
    /// every call — 284 ms at 1,000 rows, 2.5 s at 3,000, quadratic — which would have made the cache
    /// slower than no cache at the one job it has. `setDirectorySizes` is the same answer at 4050x.
    ///
    /// Deliberately does **not** render: the two callers want different things from it. A publish
    /// arriving ten times a second while a scan streams in must not re-render when nothing changed,
    /// while the toggle must render regardless (see `updateSizeVisualization`).
    @discardableResult
    private func seedFromCache() -> Bool {
        let known = DirectorySizeProvider.shared.cachedSizes(
            for: panel.model.visibleEntries.filter(\.isDirectoryLike).map(\.path),
            rule: directorySizeRule
        )
        // Only totals we don't already carry — an unchanged seed must not re-sort the listing.
        let fresh = known.filter { panel.model.directorySizes[$0.key] != $0.value }
        guard !fresh.isEmpty else { return false }
        reconcileCursorFromTable()
        panel.setDirectorySizes(fresh)
        return true
    }

    /// Queue a walk for every directory row still lacking a total.
    ///
    /// The pending list is the core's (`SizeVisualization.pendingDirectories`) rather than a filter
    /// written here, so the file/directory/symlink rule lives in one place — a symlink to a directory
    /// is walked like one, matching what the size column beside it will show.
    ///
    /// Called from `rebuildSizeVisualization` on every render pass, which is safe only because the
    /// provider de-duplicates: a child already in flight is still "pending" here (it has no total
    /// yet), so a provider that took this list at face value would walk it again on every publish.
    func requestScan() {
        guard let pending = sizeVisualization?.pendingDirectories, !pending.isEmpty else {
            DirectorySizeProvider.shared.cancelScan(for: panel.path)
            return
        }
        DirectorySizeProvider.shared.requestScan(
            for: panel.path,
            children: pending.map(\.path),
            backend: backend,
            rule: directorySizeRule
        )
    }

    /// Drop the mode's view state — switching it off, or navigating somewhere it cannot apply.
    ///
    /// **The computed sizes deliberately survive.** `panel.model.directorySizes` is not this mode's
    /// property: Space-on-dir has been writing to it since M1, and dropping totals here would erase
    /// numbers the user asked for by hand, in the size column, for a mode they merely switched off.
    private func clearSizeVisualization() {
        DirectorySizeProvider.shared.cancelScan(for: panel.path)
        setSizeBarColumnInstalled(false)
        guard sizeVisualization != nil else { return }
        sizeVisualization = nil
        // This pane just genuinely left the mode (the guard above keeps steady-state re-renders
        // out). If no tab anywhere is in it either, nobody is left to draw a bar from what the
        // walks are computing: tear the whole queue down mid-walk rather than leave an in-flight
        // `/System` walk parked on a blocking thread. A tab that merely navigated somewhere bars
        // can't apply still counts as in the mode — its walks matter again the moment it returns.
        if !isSizeVisualizationOnAnywhere {
            DirectorySizeProvider.shared.cancelAllScans()
        }
        if deferRefreshIfRenaming() { return }
        renderRefresh()
    }

    /// Whether any tab — in this pane or its counterpart — still has the mode switched on.
    private var isSizeVisualizationOnAnywhere: Bool {
        var panes = [self]
        if let other = host?.panelCounterpart(of: self) { panes.append(other) }
        return panes.contains { $0.tabs.contains(where: \.isSizeVisualizationEnabled) }
    }

    /// Tell the provider a real filesystem change landed under `path`, so cached totals on that
    /// root-to-leaf line stop being believed. Called from the pane's own FSEvents handler — the
    /// watcher we already have, since a change to this folder's tree is exactly what it reports.
    func invalidateDirectorySizes(under path: VFSPath) {
        DirectorySizeProvider.shared.invalidate(under: path)
    }

    // MARK: - The projection

    /// Rebuild the bar projection for the rows about to be drawn. Called from the pane's two render
    /// entry points (`reloadEverything`, `renderRefresh`) — between them they follow every change to
    /// the visible set, which is what the projection depends on. That matters more than it looks:
    /// **both denominators cover visible rows only**, so typing a filter or revealing dotfiles
    /// re-scales every bar, and a projection left over from the previous row set would draw
    /// confidently wrong bars.
    func rebuildSizeVisualization() {
        guard areSizeBarsVisible else {
            sizeVisualization = nil
            return
        }
        // The rule's own predicate, so an ignored folder is left out of the chart rather than shown
        // as an empty one — see `SizeVisualization.init` on why zeroing it lies.
        sizeVisualization = SizeVisualization(
            model: panel.model,
            isExcluded: directorySizeRule.exclude
        )
        // The visible set just changed, so what is pending changed with it — revealing dotfiles adds
        // 68 directories to `~` (measured), and a filter can empty the queue entirely.
        requestScan()
    }

    // MARK: - Rendering

    /// One row's bar, or `nil` when it has no total yet (or the mode is off). The `..` row never
    /// reaches here: it is synthesized by the app and the core's projection has never heard of it —
    /// see `PanelViewController+ParentRow`.
    func sizeBar(for entry: FileEntry) -> SizeBar? {
        guard areSizeBarsVisible else { return nil }
        return sizeVisualization?.bar(for: entry)
    }

    // MARK: - The bar column

    /// Install or remove the bar column to match the mode.
    func updateSizeBarColumn() {
        setSizeBarColumnInstalled(areSizeBarsVisible)
    }

    var isSizeBarColumnInstalled: Bool {
        tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(Column.sizeBar.rawValue)) >= 0
    }

    /// What the column costs the table: its width **plus one intercell spacing**, which
    /// `NSTableView` adds per column — 17 pt at this table's `.plain` style, not the 2–3 pt the name
    /// suggests. Read live rather than hardcoded, the same trap `gitColumnFootprint` documents.
    var sizeBarColumnFootprint: CGFloat {
        Column.sizeBar.defaultWidth + tableView.intercellSpacing.width
    }

    /// Add or remove the bar column, **paid for out of the Name column** — never added on top of the
    /// table, which would shove Size and Date sideways every time the mode flipped. Name is the right
    /// column to charge because it is already the one that absorbs slack
    /// (`firstColumnOnlyAutoresizingStyle`). This is a bigger bite than the Git gutter's 20 pt, and
    /// it is meant to be: the user asked for a chart, and `NSTableColumn` clamps at Name's own
    /// `minWidth` so a narrow pane keeps a legible filename regardless.
    func setSizeBarColumnInstalled(_ installed: Bool) {
        let identifier = NSUserInterfaceItemIdentifier(Column.sizeBar.rawValue)
        let existing = tableView.column(withIdentifier: identifier)
        guard installed != (existing >= 0) else { return }
        // Adding or removing a column posts the same resize/move notifications a user's header drag
        // does. Without this guard, toggling the mode would be recorded as the user having
        // rearranged their columns — and persisted.
        let wasApplyingLayout = isApplyingColumnLayout
        isApplyingColumnLayout = true
        defer { isApplyingColumnLayout = wasApplyingLayout }

        guard installed else {
            tableView.removeTableColumn(tableView.tableColumns[existing])
            resizeNameColumn(by: sizeBarColumnFootprint)
            return
        }
        resizeNameColumn(by: -sizeBarColumnFootprint)
        let column = NSTableColumn(identifier: identifier)
        column.title = Column.sizeBar.title
        column.headerToolTip = "Share of this folder"
        column.width = Column.sizeBar.defaultWidth
        column.minWidth = Column.sizeBar.minWidth
        tableView.addTableColumn(column)
        // Immediately after Size, where the bar reads as a picture *of* the number beside it. That
        // adjacency is the whole reason the core measures logical bytes rather than ncdu's allocated
        // ones: a bar twice its neighbour's beside a size column reading smaller is incoherent.
        let sizeIdentifier = NSUserInterfaceItemIdentifier(Column.size.rawValue)
        let sizeIndex = tableView.column(withIdentifier: sizeIdentifier)
        guard sizeIndex >= 0 else { return }
        tableView.moveColumn(tableView.tableColumns.count - 1, toColumn: sizeIndex + 1)
    }
}
