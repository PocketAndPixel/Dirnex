import DirnexCore

/// Virtual **results** tabs: a pane showing a set of files that share no directory — Spotlight hits
/// (PLAN.md §M4), Recents, or the merged Trash (PLAN.md §M8).
///
/// The shape is the same in every case and is what makes each of those features cheap: the tab's
/// *container* path is synthetic (`search:…`, `trash:…`) while every entry in it carries its real
/// on-disk path, so Quick Look, copying to the other pane, tags and sync badges all reach the actual
/// file. The pane recognizes such a tab through `isResultsListing` and suppresses the behavior that
/// assumes a real directory underneath: watching it, re-listing it by path, the `..` row, and the
/// in-place mutations (New Folder, rename, paste).
///
/// Split out of `PanelViewController+Search` when Trash became the third caller — the installer was
/// never search-specific, and leaving it there would have made the Trash import a search.
extension PanelViewController {
    /// The active tab shows a virtual results listing rather than a real directory.
    ///
    /// Prefer this over `isSearchResults` for anything that reasons about the *shape* of the tab;
    /// `isSearchResults` means specifically "these are Spotlight hits" and gates search-only things
    /// like "Save Search…".
    var isResultsListing: Bool {
        panel.path.backend == .search || panel.path.backend == .trash || panel.path.backend == .icloud
    }

    /// How a virtual results tab presents its hits — everything that differs between an ⌥F7/saved
    /// search, Recents and the Trash, bundled so `openResults` stays within its parameter budget.
    struct ResultsPresentation {
        /// The stable English `pathSummary` the Recents listing is identified by. Never displayed —
        /// the tab title and path-bar label localize separately — but the path bar matches on it to
        /// self-name Recents rather than borrow the "Results for …" phrasing (see
        /// `rebuildVirtualLabel`), exactly as the Trash matches on `backend == .trash`. Defined in
        /// the core, because the sidebar's Focus Sidebar recognizes the tab by it too.
        static let recentsIdentity = RecentsQuery.listingName

        /// The synthetic container's backend: `.search` for hits, `.trash` for the merged Trash.
        var backend: VFSBackendID = .search
        /// The synthetic path's last component and the path-bar crumb.
        let pathSummary: String
        /// The listing order — the pane's own sort for a search or the Trash, recency for Recents.
        let sort: FileSort
        /// What "Save Search…" persists; `nil` for Recents and the Trash, which aren't queries.
        let query: FileQuery?
        let scope: VFSPath?
        /// The chip label; `nil` on an ad-hoc search leaves the query-summary crumb.
        let title: String?
        /// The folder ⌥F7 was pressed in, which editing the search offers again (`PanelTab`);
        /// `nil` for everything that was not started from the dialog.
        var origin: VFSPath?
        /// Whether dotfiles show. `true` for hits the user explicitly asked for — a matched search
        /// or a recently-used file shouldn't be hidden by the app-wide toggle — but the Trash passes
        /// the pane's own setting, because its dotfiles are Finder's `.DS_Store` put-back databases
        /// rather than anything the user put there.
        var showsHidden: Bool = true
    }

    /// Install already-gathered entries as a new virtual tab beside the current one and switch to
    /// it, so the user's browsing tab is preserved (closing the results tab with ⌘W returns to it).
    /// The tab is marked loaded so nothing tries to re-list the synthetic path.
    func openResults(
        _ entries: [FileEntry],
        truncated: Bool,
        as presentation: ResultsPresentation
    ) {
        captureColumnLayout()
        let tab = PanelTab(panel: Panel(model: resultsModel(entries, as: presentation)))
        tab.columnLayout = tabs[activeTabIndex].columnLayout
        record(presentation, on: tab)

        tabs.insert(tab, at: activeTabIndex + 1)
        activeTabIndex += 1
        activateTab()
        persistState()
        focusTable()

        if truncated { presentTruncationNotice() }
    }

    /// Mark `tab` as holding the listing `presentation` describes: loaded, so nothing tries to
    /// re-list the synthetic path, and carrying what produced it — the query and scope "Save
    /// Search…" persists and an edit re-opens (nil for Recents and the Trash), and the chip label a
    /// saved search, Recents or the Trash names its tab with (an ad-hoc ⌥F7 search leaves the
    /// query-summary chip).
    func record(_ presentation: ResultsPresentation, on tab: PanelTab) {
        tab.hasLoaded = true
        tab.searchQuery = presentation.query
        tab.searchScope = presentation.scope
        tab.searchOrigin = presentation.origin
        tab.customTitle = presentation.title
        // New hits: what left the old ones is no longer this snapshot's to bring back.
        tab.departedSearchHits = [:]
    }

    /// The search matched more than a results tab holds. Shared by a new results tab and an edited
    /// one, since the cap is the same whichever tab the hits land in.
    func presentTruncationNotice() {
        presentOperationFailure(
            message: String(
                localized: "Showing the first \(SpotlightSearchRunner.resultLimit) results",
                comment: "Search-results truncation title; %lld is the fixed result cap."
            ),
            detail: String(
                localized: "Your search matched more items. Narrow it to see the rest.",
                comment: "Search-results truncation body."
            )
        )
    }

    /// Install gathered entries into the tab **already active**, the way navigating to a directory
    /// replaces its listing — for a virtual listing that names a place rather than a query.
    ///
    /// iCloud Drive is one caller: a user clicks it repeatedly while browsing, and `openResults`'
    /// tab-per-click is right for a search or the Trash but stacks up for a destination. An edited
    /// search is the other, for the same reason one step removed — changing a condition is still the
    /// same question, and a tab per change would stack up just as fast (`+SearchEdit`). Everything
    /// a `navigate` does for the pane's chrome happens here too, minus the parts that only mean
    /// something for a real directory — the load is already done, the synthetic path is not
    /// watchable, and it never enters the back/forward trail (it can't be re-listed by path, so
    /// Back returns to wherever the tab was before, which is what the user came from).
    func installResults(_ entries: [FileEntry], as presentation: ResultsPresentation) {
        // Any directory load still in flight would land after this and overwrite the merge.
        loadToken += 1
        let departed = panel.path
        panel.setModel(resultsModel(entries, as: presentation))
        // The same line `navigate` runs here, and for the same reason: `setModel` *keeps* a tree
        // across a navigation (re-rooted, all collapsed), so a pane that was a tree when the user
        // clicked would go on drawing disclosure triangles over a listing where a tree cannot apply.
        // The menu item reads its checkmark from the pane's real shape and its enablement from
        // `canUseTreeMode`, so without this it renders ticked *and* gray — the menu is the only way
        // to answer it, and a shortcut bound to the command is dead too, since a disabled item
        // swallows its own key equivalent (docs/NOTES.md ▸ AppKit).
        applyViewMode()
        resetMouseSelectionAnchor()
        // A results listing has no `..` row to park on, however empty it is.
        cursorOnParentRow = false

        record(presentation, on: tabs[activeTabIndex])

        // Re-points the FSEvents watcher: the synthetic path is not a directory, so in list mode this
        // watches whatever the merge was gathered from (or nothing, for a search snapshot) rather than
        // leaving the watcher on the folder we came from, which would re-list *that* into this pane.
        // Through `startPaneWatcher` rather than `startWatching` because the tab may be a tree by the
        // time it gets here, and a tree watches its expanded children as well as those sources.
        startPaneWatcher(panel.path)
        DirectorySizeProvider.shared.cancelScan(for: departed)
        reloadEverything()
        refreshTabBar()
        updateGitStatus()
        updateTagStatus()
        updateSyncStatus()
        updateSizeVisualization()
        persistState()
        host?.panelDidNavigate(self)
    }

    /// Put one hit back under the name the app just gave it.
    ///
    /// A search snapshot is the one listing here that can neither re-list nor re-gather itself —
    /// `refreshCurrentDirectory` returns without touching it, and `refreshTree` deliberately skips a
    /// results root, both saying the same thing: it keeps the hits it was given. That is right for
    /// the world changing underneath it, and wrong for a change *this pane* made, which would
    /// otherwise leave the row showing a name that is no longer on disk — the tell the S3 rename bug
    /// was first reported by.
    ///
    /// A substitution rather than a re-`stat`: a rename changes nothing but the name, and the hit
    /// may be on a server, where confirming what we just did would be a round trip. Nothing else in
    /// the snapshot moves, so a search that found a hundred files still shows a hundred.
    ///
    /// The merged Trash and iCloud listings need none of this — both re-gather on refresh. A rename
    /// that had to run as a **job** (an S3 prefix, `EXDEV`) lands through `applySearchHitChanges`
    /// instead, once the window hears the job finish: it is a move that stayed in its own folder.
    func substituteSearchHit(_ source: VFSPath, renamedTo newName: String) {
        guard panel.path.backend == .search else { return }
        let entries = panel.model.listing.entries
        guard entries.contains(where: { $0.path == source }) else { return }
        panel.setListing(DirectoryListing(
            path: panel.path,
            entries: entries.map { $0.path == source ? $0.renamed(to: newName) : $0 }
        ))
        if let index = panel.displayedIndex(ofID: source.parent?.appending(newName) ?? source) {
            panel.moveCursor(to: index)
        }
        reloadEverything()
    }

    /// Apply what a delete or a move did to search hits, in every results tab of this pane that
    /// holds them — the rename's twin above, for the same reason: a snapshot cannot re-list, so a
    /// hit that left would go on showing a file that is no longer there. A move that stayed in the
    /// hit's own folder is a queued rename, and the row takes the new name (`SearchSnapshot`).
    ///
    /// Every results tab rather than the one the gesture started in, because the question is about
    /// the *file*. A move reaches the window only when its job finishes, with no tab attached, and a
    /// delete over a server takes long enough to switch tabs under; any tab showing the hit is
    /// showing a file that is not there. Rows inside an expanded folder are not hits, and are left
    /// to the tree's re-list of that folder.
    ///
    /// A hit that can come back is remembered (`PanelTab.departedSearchHits`), so ⌘Z restores its
    /// row: when `canReturn` — a Trash pass or a move, never a permanent delete — and only on this
    /// Mac, because following it costs a `stat` per hit on every refresh of the tab, which on a
    /// server would be a round trip apiece.
    func applySearchHitChanges(_ changes: [SearchSnapshot.Change], canReturn: Bool) {
        guard !changes.isEmpty else { return }
        for tab in tabs where tab.panel.path.backend == .search {
            let cursor = tab.panel.currentEntry?.path
            guard let applied = SearchSnapshot.applying(changes, to: tab.panel.model.listing.entries)
            else { continue }
            if canReturn {
                for entry in applied.departed where entry.path.backend == .local {
                    tab.departedSearchHits[entry.path] = entry
                }
            }
            // A renamed row re-sorts under its new name; the cursor goes with it, as it does after
            // an in-place rename.
            let renamedCursor = changes.lazy.compactMap { change -> VFSPath? in
                guard case let .moved(source, landing) = change, source == cursor else { return nil }
                return landing
            }.first
            installSearchHits(applied.entries, in: tab, cursorOn: renamedCursor)
        }
    }

    /// Tell every results tab in the window what a delete took away: this pane's, and the other
    /// pane's, which may be showing the same hits (`applySearchHitChanges`).
    func noteSearchHitsDeleted(_ paths: [VFSPath], permanent: Bool) {
        let changes = paths.map(SearchSnapshot.Change.removed)
        applySearchHitChanges(changes, canReturn: !permanent)
        host?.panelCounterpart(of: self)?.applySearchHitChanges(changes, canReturn: !permanent)
    }

    /// Show again the hits that left this tab and are back where they were, and drop any that went
    /// again — so ⌘Z after a delete or a move restores the row along with the file, and ⇧⌘Z takes
    /// both away again (`SearchSnapshot`).
    ///
    /// Asked of the disk rather than of the undo record, which is what makes an undo that only put
    /// back some of the items land right, and it costs nothing where nothing departed. Runs on every
    /// refresh of the active search tab, and when the tab is switched back to — undo refreshes only
    /// the tabs on screen.
    func reconcileDepartedSearchHits() {
        let tab = tabs[activeTabIndex]
        let departed = Array(tab.departedSearchHits.values)
        guard tab.panel.path.backend == .search, !departed.isEmpty else { return }
        let backend = backend
        Task {
            let present = await BlockingWork.run {
                SearchSnapshot.present(departed.map(\.path), using: backend)
            }
            guard tab.panel.path.backend == .search, tabs.contains(where: { $0 === tab }),
                  let entries = SearchSnapshot.reconciled(
                      tab.panel.model.listing.entries,
                      departed: departed,
                      present: present
                  )
            else { return }
            installSearchHits(entries, in: tab)
        }
    }

    /// Replace `tab`'s hits in place, keeping the cursor and marks by identity. The active tab is
    /// redrawn; a background one renders what it holds when it is switched back to.
    private func installSearchHits(
        _ entries: [FileEntry],
        in tab: PanelTab,
        cursorOn target: VFSPath? = nil
    ) {
        let isActive = tab === tabs[activeTabIndex]
        // The table's selection is the live cursor until its change notification lands, and the
        // re-anchor below starts from the model's.
        if isActive { reconcileCursorFromTable() }
        tab.panel.setListing(DirectoryListing(path: tab.panel.path, entries: entries))
        if let target, let index = tab.panel.displayedIndex(ofID: target) {
            tab.panel.moveCursor(to: index)
        }
        guard isActive else { return }
        reloadEverything()
    }

    /// The model behind a results tab — shared by opening one and by re-gathering an open one
    /// (which the Trash does after a delete, since unlike a search snapshot its contents change
    /// because of what the user just did in it).
    func resultsModel(
        _ entries: [FileEntry],
        as presentation: ResultsPresentation
    ) -> DirectoryModel {
        let listing = DirectoryListing(
            path: VFSPath(backend: presentation.backend, path: "/" + presentation.pathSummary),
            entries: entries
        )
        return DirectoryModel(
            listing: listing,
            sort: presentation.sort,
            showHidden: presentation.showsHidden
        )
    }
}
