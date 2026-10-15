import AppKit
import DirnexCore

/// Editing the search behind a results tab: ⌥F7 on a tab of search hits, or a click on its
/// "Results for …" label in the path bar, opens Find Files filled in with that search, and Find
/// runs the edited search back into the same tab.
///
/// **In place rather than in a new tab**, because changing a condition is still the same question
/// and a tab per change would stack up — the reason iCloud Drive moved to `installResults` too. The
/// results being replaced are one `+` away from being kept: that button already copies a results
/// snapshot into a tab of its own.
///
/// **A saved search's name comes off the chip once its conditions change**, since the name no longer
/// describes what the tab holds. Save Search… offers it again (`titleBeforeEdit`), so updating the
/// saved search is one confirmation away and never happens behind the user's back. Running the
/// search again unchanged keeps the name — the same rule by which the sidebar recognizes a saved
/// search's tab (`SidebarPlaceLocator`: the query and the scope).
extension PanelViewController {
    /// Where a finished search's hits land, and what the tab they land in remembers about it.
    struct SearchLanding {
        /// A new tab's chip label — a saved search's or a tag's name; `nil` leaves the query
        /// summary. An edit ignores it: its label follows the rule at the top of this file.
        var title: String?
        /// The folder ⌥F7 was pressed in (`PanelTab.searchOrigin`).
        var origin: VFSPath?
        /// The results tab an edit runs back into; `nil` opens a new one.
        var tab: PanelTab?
    }

    /// Whether the active tab holds a search to edit: any tab of search hits, but not Recents,
    /// which rides the same machinery with no query behind it.
    var canEditCurrentSearch: Bool {
        isSearchResults && tabs[activeTabIndex].searchQuery != nil
    }

    /// Open Find Files on the active tab's search.
    func editCurrentSearch() {
        guard let controller = makeEditSearchController() else { return }
        presentAsMovableWindow(controller)
    }

    /// The dialog an edit opens: filled in with the active tab's search, asking about the real
    /// folder that search ran in, and wired to run the edited search back into this tab. `nil` when
    /// there is no search here, or when the search cannot be shown without losing part of it — after
    /// saying so.
    func makeEditSearchController() -> SearchController? {
        let tab = tabs[activeTabIndex]
        guard isSearchResults, let query = tab.searchQuery else { return nil }
        let place = SearchPlace(
            scope: tab.searchScope,
            origin: tab.searchOrigin,
            home: .local(NSHomeDirectory())
        )
        guard place.route != .unavailable else {
            presentUnsearchableScope(at: place.folder)
            return nil
        }
        // The dialog hides the fields its folder cannot answer, and a hidden field adds nothing to
        // the query it builds — so a term outside `fields` would vanish from the edited search
        // without a word. No tab holds one today: a walk refuses such a query before it runs, and
        // Spotlight answers every field. This keeps it that way if a tab ever does.
        let unanswerable = SearchPredicate.unanswerable(in: query, given: place.fields)
        guard unanswerable.isEmpty else {
            presentUnanswerable(SearchQueryUnanswerable(fields: unanswerable), at: place.folder)
            return nil
        }

        let controller = makeSearchController(searching: place.folder)
        controller.open(on: query, everything: place.everything)
        // Weak: a tab closed while its search runs is gone, and the hits then open a tab of their
        // own rather than vanishing (`landSearchResults`).
        controller.onSearch = { [weak self, weak tab] query, choice in
            self?.runSearch(
                query,
                in: SearchPlace(folder: place.folder, everything: choice == .everything),
                landing: SearchLanding(tab: tab)
            )
        }
        return controller
    }

    /// Put a finished search's hits where `landing` says: back into the tab being edited, or into a
    /// new results tab beside the current one.
    ///
    /// The edited tab is found by identity, not by index, and need not be the active one: a
    /// Spotlight search over file contents can take seconds, and the user may switch tabs meanwhile.
    /// It must still be holding a search, though — a tab navigated off to a folder while the search
    /// ran has stopped being one, and replacing its listing would yank the user out of that folder.
    /// The hits open a tab of their own then.
    func landSearchResults(
        _ entries: [FileEntry],
        truncated: Bool,
        query: FileQuery,
        scope: VFSPath?,
        landing: SearchLanding
    ) {
        guard let tab = landing.tab,
              let index = tabs.firstIndex(where: { $0 === tab }),
              tab.panel.path.backend == .search,
              tab.searchQuery != nil
        else {
            openResults(
                entries,
                truncated: truncated,
                as: ResultsPresentation(
                    pathSummary: LocalizedCatalog.summary(of: query),
                    sort: panel.model.sort,
                    query: query,
                    scope: scope,
                    title: landing.title,
                    origin: landing.origin
                )
            )
            return
        }

        let unchanged = query == tab.searchQuery && scope == tab.searchScope
        let titleBeforeEdit = unchanged ? tab.titleBeforeEdit : tab.customTitle ?? tab.titleBeforeEdit
        replaceResults(
            entries,
            in: tab,
            at: index,
            as: ResultsPresentation(
                pathSummary: LocalizedCatalog.summary(of: query),
                // The tab's own sort, which the user may have changed there — not the pane's, which
                // is whatever tab happens to be active when the hits land.
                sort: tab.panel.model.sort,
                query: query,
                scope: scope,
                title: unchanged ? tab.customTitle : nil,
                origin: landing.origin
            )
        )
        tab.titleBeforeEdit = titleBeforeEdit
        if truncated { presentTruncationNotice() }
    }

    /// Swap `tab`'s hits for `entries`. The active tab goes through `installResults`, which redraws
    /// the pane; a tab in the background only needs its stored state replaced, which it renders when
    /// it is switched back to.
    private func replaceResults(
        _ entries: [FileEntry],
        in tab: PanelTab,
        at index: Int,
        as presentation: ResultsPresentation
    ) {
        guard index == activeTabIndex else {
            tab.panel.setModel(resultsModel(entries, as: presentation))
            record(presentation, on: tab)
            refreshTabBar()
            return
        }
        installResults(entries, as: presentation)
        focusTable()
    }
}
