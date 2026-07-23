import AppKit
import DirnexCore

/// Virtual **results** tabs: a pane showing a set of files that share no directory — Spotlight hits
/// (PLAN.md §M4), Recents, or the merged Trash (PLAN.md §M8).
///
/// The shape is the same in every case and is what makes each of those features cheap: the tab's
/// *container* path is synthetic (`search:…`, `trash:…`) while every entry in it carries its real
/// on-disk path, so Quick Look, copying to the other pane, tags and sync badges all reach the actual
/// file. The pane recognises such a tab through `isResultsListing` and suppresses the behavior that
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
        /// `rebuildVirtualLabel`), exactly as the Trash matches on `backend == .trash`.
        static let recentsIdentity = "Recents"

        /// The synthetic container's backend: `.search` for hits, `.trash` for the merged Trash.
        var backend: VFSBackendID = .search
        /// The synthetic path's last component and the path-bar crumb.
        let pathSummary: String
        /// The listing order — the pane's own sort for a search or the Trash, recency for Recents.
        let sort: FileSort
        /// What "Save Search…" persists; `nil` for Recents and the Trash, which aren't queries.
        let query: SpotlightQuery?
        let scope: VFSPath?
        /// The chip label; `nil` on an ad-hoc search leaves the query-summary crumb.
        let title: String?
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
        tab.hasLoaded = true
        tab.columnLayout = tabs[activeTabIndex].columnLayout
        // Retain what produced these results so "Save Search…" can persist it (nil elsewhere).
        tab.searchQuery = presentation.query
        tab.searchScope = presentation.scope
        // A saved search / Recents / the Trash names its results tab; an ad-hoc ⌥F7 search leaves
        // the query-summary chip.
        tab.customTitle = presentation.title

        tabs.insert(tab, at: activeTabIndex + 1)
        activeTabIndex += 1
        activateTab()
        persistState()
        focusTable()

        if truncated {
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
    }

    /// Install gathered entries into the tab **already active**, the way navigating to a directory
    /// replaces its listing — for a virtual listing that names a place rather than a query.
    ///
    /// iCloud Drive is the caller: a user clicks it repeatedly while browsing, and `openResults`'
    /// tab-per-click is right for a search or the Trash but stacks up for a destination. Everything
    /// a `navigate` does for the pane's chrome happens here too, minus the parts that only mean
    /// something for a real directory — the load is already done, the synthetic path is not
    /// watchable, and it never enters the back/forward trail (it can't be re-listed by path, so
    /// Back returns to wherever the tab was before, which is what the user came from).
    func installResults(_ entries: [FileEntry], as presentation: ResultsPresentation) {
        // Any directory load still in flight would land after this and overwrite the merge.
        loadToken += 1
        let departed = panel.path
        panel.setModel(resultsModel(entries, as: presentation))
        resetMouseSelectionAnchor()
        // A results listing has no `..` row to park on, however empty it is.
        cursorOnParentRow = false

        let tab = tabs[activeTabIndex]
        tab.hasLoaded = true
        tab.searchQuery = presentation.query
        tab.searchScope = presentation.scope
        tab.customTitle = presentation.title

        // Drops the FSEvents watcher: the synthetic path is not a directory, and a watcher left on
        // the folder we came from would re-list *that* into this pane.
        startWatching(panel.path)
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
