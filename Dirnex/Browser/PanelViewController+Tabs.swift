import AppKit
import DirnexCore

/// Per-pane tabs (PLAN.md §M1 "tabs per panel: new/close/reorder, restored on
/// relaunch"). A pane owns an array of `PanelTab`s and renders the active one; all of
/// the add/close/select/reorder plumbing — plus the `TabBarView` delegate and the
/// menu actions that drive it from the keyboard — lives here to keep the controller
/// proper focused on a single directory.
extension PanelViewController {
    // MARK: - Activation

    /// Show whichever tab is active. A tab that has never been listed (fresh, or just
    /// restored from disk) is loaded from scratch; a tab we're returning to renders its
    /// stored cursor/marks/filter instantly, then refreshes in the background so it is
    /// current after having been unwatched while inactive.
    func activateTab() {
        applyColumnLayout(for: tabs[activeTabIndex])
        refreshTabBar()
        if tabs[activeTabIndex].hasLoaded {
            reloadEverything()
            refreshActiveDirectory()
            // The tab renders its own stored Git state immediately (it is per-tab, like the cursor);
            // this re-points the pane's single repository watcher at it and refreshes what may have
            // gone stale while the tab was inactive. A fresh tab gets both from `navigate`.
            updateGitStatus()
            updateTagStatus()
            updateSyncStatus()
            // Same reasoning, and the mode is per tab: switching to a tab that had bars on must
            // re-queue the walks that were abandoned when it went inactive, while a tab that had
            // them off must not inherit the outgoing tab's column.
            updateSizeVisualization()
        } else {
            navigate(to: panel.path)
        }
        // The switched-to tab owns its own back/forward trail — re-validate the titlebar buttons.
        host?.panelDidNavigate(self)
    }

    /// Re-list the active tab's directory without moving the cursor or scroll position —
    /// the tab may have gone stale while inactive (nothing watches an inactive tab). A virtual
    /// results tab has no directory to re-list; its snapshot stands until the tab is closed.
    private func refreshActiveDirectory() {
        guard panel.path.backend == .local else { return }
        loadToken += 1
        let token = loadToken
        let path = panel.path
        let index = activeTabIndex
        startWatching(path)
        // Off-main sort (PLAN.md §M7 perf pass): re-activating a stale 100k tab must not re-sort on
        // the main actor. `installSortedModel` re-applies the live filter and any in-flight total.
        let sort = panel.model.sort
        let showHidden = panel.model.showHidden
        let sizes = panel.model.directorySizes
        Task {
            guard let model = try? await DirectoryLoader.model(
                backend, at: path, sort: sort, showHidden: showHidden, directorySizes: sizes
            ) else { return }
            guard token == loadToken, panel.path == path, activeTabIndex == index else { return }
            reconcileCursorFromTable()
            installSortedModel(model)
            tabs[index].hasLoaded = true
            renderRefresh()
        }
    }

    /// Rebuild the tab strip from the current tab list; the strip hides itself when a
    /// pane has a single tab so the browser looks unchanged until a second one is opened.
    func refreshTabBar() {
        tabBar.isHidden = tabs.count <= 1
        tabBar.setTabs(tabs.map(\.title), activeIndex: activeTabIndex)
        tabBar.isActivePane = isActivePanel
    }

    // MARK: - Operations

    /// Open `path` in a fresh tab beside the active one, inheriting this pane's sort/hidden and
    /// column layout so it matches the pane it lands in. Used to land a folder opened from a
    /// search-results tab into a real directory tab (in the other pane, or this one when there's
    /// no counterpart) without disturbing the results — see `PanelViewController+Navigation`.
    ///
    /// `activate` switches to the new tab (loading it) when `true`; when `false` the tab is
    /// inserted in the background and the currently shown tab (e.g. the search results) stays put.
    func openInNewTab(_ path: VFSPath, activate: Bool = true) {
        captureColumnLayout()
        let tab = PanelTab(
            path: path,
            sort: panel.model.sort,
            showHidden: panel.model.showHidden,
            columns: tabs[activeTabIndex].columnLayout
        )
        tabs.insert(tab, at: activeTabIndex + 1)
        if activate {
            activeTabIndex += 1
            activateTab()
        } else {
            refreshTabBar()
        }
        persistState()
    }

    /// Open a new tab beside the current one, showing the same directory and inheriting
    /// its sort/hidden settings (Cmd+T / the tab strip's `+`).
    func addTab() {
        // Snapshot the current tab's live column geometry first, so the new tab inherits
        // exactly what's on screen (matching the sort/hidden inheritance below).
        captureColumnLayout()
        let currentTab = tabs[activeTabIndex]
        let tab = newTab(basedOn: currentTab)
        tab.columnLayout = currentTab.columnLayout
        tabs.insert(tab, at: activeTabIndex + 1)
        activeTabIndex += 1
        activateTab()
        persistState()
    }

    /// Build the tab `+` opens. Normally a fresh tab at the same directory (loaded on activate).
    /// A **search-results** tab has no real directory — cloning its virtual `search:` path would
    /// make `activateTab` navigate a backend nothing can list ("No backend can handle search:/…"),
    /// so instead duplicate the results snapshot (marked already-loaded, carrying the query) so
    /// `+` just opens another view of the same hits with no error.
    private func newTab(basedOn currentTab: PanelTab) -> PanelTab {
        guard isResultsListing else {
            return PanelTab(
                path: panel.path,
                sort: panel.model.sort,
                showHidden: panel.model.showHidden
            )
        }
        let duplicate = PanelTab(panel: panel) // `panel` is a value type → an independent copy
        duplicate.hasLoaded = true
        duplicate.searchQuery = currentTab.searchQuery
        duplicate.searchScope = currentTab.searchScope
        duplicate.customTitle = currentTab.customTitle
        return duplicate
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count, index != activeTabIndex else { return }
        activeTabIndex = index
        activateTab()
        persistState()
    }

    // MARK: - Volume recovery

    /// A volume was unmounted (ejected from the sidebar, in Finder, or via `diskutil`). Any tab
    /// still pointing inside it now shows a stale, unusable listing, so redirect it to Home. The
    /// active tab re-navigates (re-listing Home and refreshing the chrome); a background tab is
    /// reset to a fresh, not-yet-loaded Home so it loads cleanly the next time it's shown.
    /// Reports whether any tab was affected.
    @discardableResult
    func recoverIfBrowsing(unmountedVolumeAt mountPoint: VFSPath) -> Bool {
        let home = VFSPath.local(NSHomeDirectory())
        var activeNavigated = false
        var changed = false
        for (index, tab) in tabs.enumerated()
            where tab.panel.path.isSelfOrDescendant(of: mountPoint) {
            changed = true
            if index == activeTabIndex {
                navigate(to: home)
                activeNavigated = true
            } else {
                reset(tab, to: home)
            }
        }
        guard changed else { return false }
        // `navigate` refreshes the tab strip and persists on its own; only do it here when the
        // active tab stayed put and merely background tabs were reset.
        if !activeNavigated {
            refreshTabBar()
            persistState()
        }
        return true
    }

    /// Point a background tab back at `path`, discarding the state it held for the vanished
    /// directory so it loads afresh the next time it's activated.
    private func reset(_ tab: PanelTab, to path: VFSPath) {
        tab.panel = Panel(
            path: path,
            sort: tab.panel.model.sort,
            showHidden: tab.panel.model.showHidden
        )
        tab.history = NavigationHistory(initialPath: path)
        tab.hasLoaded = false
        tab.cursorOnParentRow = false
        tab.searchQuery = nil
        tab.searchScope = nil
        tab.customTitle = nil
    }

    func selectNextTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        guard tabs.count > 1 else { return }
        selectTab(at: (activeTabIndex - 1 + tabs.count) % tabs.count)
    }

    /// Close the tab at `index`. The last tab is never closed here (the caller closes the
    /// window instead, matching macOS Cmd+W), so this reports whether one was removed.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, index >= 0, index < tabs.count else { return false }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if index < activeTabIndex {
            activeTabIndex -= 1
        }
        activateTab()
        persistState()
        return true
    }

    /// Reorder a tab, keeping the same tab active across the move (identity, not index).
    func moveTab(from source: Int, to destination: Int) {
        guard source >= 0, source < tabs.count, source != destination else { return }
        let activeTab = tabs[activeTabIndex]
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
        activeTabIndex = tabs.firstIndex { $0 === activeTab } ?? activeTabIndex
        refreshTabBar()
        persistState()
    }

    // MARK: - Persistence

    /// Write this pane's tabs (paths + per-tab sort) so they survive a relaunch.
    func persistState() {
        guard let restorationKey else { return }
        let persisted = tabs.map {
            PersistedTab(path: $0.panel.path, sort: $0.panel.model.sort, columns: $0.columnLayout)
        }
        TabPersistence.save(
            PersistedPane(tabs: persisted, activeIndex: activeTabIndex),
            paneKey: restorationKey
        )
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
            return PanelTab(
                path: path,
                sort: persisted.fileSort,
                showHidden: showHidden,
                columns: persisted.columns
            )
        }
    }

    // MARK: - Menu actions (dispatched to the focused pane via the responder chain)

    @objc func newTab(_ sender: Any?) {
        addTab()
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        // Closing the final tab closes the window, the standard macOS Cmd+W behavior.
        if !closeTab(at: activeTabIndex) {
            view.window?.performClose(sender)
        }
    }

    @objc func showNextTab(_ sender: Any?) {
        selectNextTab()
    }

    @objc func showPreviousTab(_ sender: Any?) {
        selectPreviousTab()
    }
}

// MARK: - TabBarViewDelegate

extension PanelViewController: TabBarViewDelegate {
    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int) {
        selectTab(at: index)
        focusTable()
    }

    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int) {
        closeTab(at: index)
        focusTable()
    }

    func tabBar(_ bar: TabBarView, didMoveTabFrom source: Int, to destination: Int) {
        moveTab(from: source, to: destination)
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) {
        addTab()
        focusTable()
    }
}
