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
        panel.path.backend == .search || panel.path.backend == .trash
    }

    /// How a virtual results tab presents its hits — everything that differs between an ⌥F7/saved
    /// search, Recents and the Trash, bundled so `openResults` stays within its parameter budget.
    struct ResultsPresentation {
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
                message: "Showing the first \(SpotlightSearchRunner.resultLimit) results",
                detail: "Your search matched more items. Narrow it to see the rest."
            )
        }
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
