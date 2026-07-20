import AppKit
import DirnexCore

/// Spotlight file search (⌥F7 / palette "Find Files…") — PLAN.md §M4 "Search (Alt+F7 / palette):
/// mdfind-backed name+content search" and "Search results → virtual panel listing".
///
/// The pane presents the `SearchController` sheet, runs the resulting `SpotlightQuery` through
/// `SpotlightSearchRunner` off the main thread, and installs the hits as a **virtual results
/// tab**: a `PanelTab` on the synthetic `.search` backend whose entries carry their real
/// on-disk paths. The tab supports the normal cursor/selection and Copy-to-the-other-pane (F5)
/// the plan calls for; the pane recognizes it via `isSearchResults` and suppresses the
/// directory-bound behavior (watching, re-listing, the `..` row, in-place mutations).
extension PanelViewController {
    /// Whether the active tab is showing Spotlight search results rather than a real directory.
    /// Everything that assumes a listable, writable, watchable directory checks this first.
    var isSearchResults: Bool {
        panel.path.backend == .search
    }

    // MARK: - Menu / key action (dispatched to the focused pane via the responder chain)

    @objc func findFiles(_ sender: Any?) {
        let controller = SearchController(currentFolderName: searchScopeDirectory().lastComponent)
        controller.onSearch = { [weak self] query, scopeToFolder in
            self?.runSearch(query, scopeToCurrentFolder: scopeToFolder)
        }
        presentAsSheet(controller)
    }

    // MARK: - Running the search

    /// The real directory a "This Folder" search scopes to — the current directory when the pane
    /// shows one, else Home (a results pane has no real directory of its own to search within).
    private func searchScopeDirectory() -> VFSPath {
        panel.path.backend == .local ? panel.path : .local(NSHomeDirectory())
    }

    private func runSearch(_ query: SpotlightQuery, scopeToCurrentFolder: Bool) {
        let scope: VFSPath? = scopeToCurrentFolder ? searchScopeDirectory() : nil
        performSearch(query, scope: scope)
    }

    /// Re-run a saved search from the sidebar (PLAN.md §M4 "Saved searches … in the places
    /// strip"). Unlike ⌥F7, its scope is the absolute path stored with the search — it doesn't
    /// follow the pane's current directory — so a "Pictures" saved search always searches
    /// Pictures wherever you invoke it.
    func runSavedSearch(_ savedSearch: SavedSearch) {
        // A saved search carries a friendly name — label its results tab with it, not the raw query.
        performSearch(savedSearch.query, scope: savedSearch.scope, title: savedSearch.name)
    }

    /// Find every file carrying `tag`, from the sidebar's Tags section (PLAN.md §M6 "Finder tags:
    /// … filter chips in search").
    ///
    /// Searches **everywhere**, like Finder's sidebar tags and unlike ⌥F7's "This Folder" — a tag is
    /// a thing you put on files so you can find them again wherever you left them, so scoping it to
    /// whatever folder happens to be open would defeat the point of having tagged them.
    ///
    /// Matched by name only, because a name is all Spotlight indexes (`SpotlightQuery.tags`) — which
    /// costs nothing here, since a tag *is* its name to macOS and the colour is only how it is drawn.
    func runTagSearch(_ tag: FinderTag) {
        performSearch(SpotlightQuery(tags: [tag.name]), scope: nil, title: tag.name)
    }

    /// Run `query` within `scope` (its subtree), or everywhere when `scope` is `nil`, off the
    /// main thread, then install the hits as a virtual results tab. `title`, when given, is the
    /// tab's chip label (a saved search's name); a fresh ⌥F7 search leaves it `nil` and the chip
    /// shows the query summary.
    private func performSearch(_ query: SpotlightQuery, scope: VFSPath?, title: String? = nil) {
        let backend = backend
        Task {
            let results = await SpotlightSearchRunner.run(query, scope: scope, backend: backend)
            openSearchResults(
                results.entries,
                query: query,
                scope: scope,
                truncated: results.truncated,
                title: title
            )
        }
    }

    // MARK: - Recents

    /// Show Finder's **Recents** — recently-used files, everywhere — in a virtual results tab
    /// (PLAN.md §M8 "Recents row … reuses machinery instead of adding some"). Reached from the
    /// sidebar's first row; runs off the main thread like a search and lands in the same virtual
    /// results panel, sorted by `RecentsQuery.resultSort` (newest first) rather than the pane's sort.
    ///
    /// `searchQuery` is left `nil`, so "Save Search…" stays disabled: Recents is a fixed system
    /// listing, not a query a user composed and might want to keep.
    func showRecents() {
        let backend = backend
        Task {
            let results = await SpotlightSearchRunner.runRecents(RecentsQuery(), backend: backend)
            openResults(
                results.entries,
                truncated: results.truncated,
                as: ResultsPresentation(
                    pathSummary: "Recents",
                    sort: RecentsQuery.resultSort,
                    query: nil,
                    scope: nil,
                    title: "Recents"
                )
            )
        }
    }

    // MARK: - Virtual results tab

    /// Install the hits as a new virtual tab beside the current one and switch to it, so the
    /// user's browsing tab is preserved (closing the results tab with ⌘W returns to it). Results
    /// are a snapshot: the tab is marked loaded so nothing tries to re-list the synthetic path.
    private func openSearchResults(
        _ entries: [FileEntry],
        query: SpotlightQuery,
        scope: VFSPath?,
        truncated: Bool,
        title: String? = nil
    ) {
        openResults(
            entries,
            truncated: truncated,
            as: ResultsPresentation(
                pathSummary: query.summary,
                sort: panel.model.sort,
                query: query,
                scope: scope,
                title: title
            )
        )
    }

    /// How a virtual results tab presents its hits — everything that differs between an ⌥F7/saved
    /// search and Recents, bundled so `openResults` stays within its parameter budget.
    private struct ResultsPresentation {
        /// The synthetic `.search` path's last component and the path-bar crumb.
        let pathSummary: String
        /// The listing order — the pane's own sort for a search, recency for Recents.
        let sort: FileSort
        /// What "Save Search…" persists; `nil` for Recents, which isn't a savable query.
        let query: SpotlightQuery?
        let scope: VFSPath?
        /// The chip label; `nil` on an ad-hoc search leaves the query-summary crumb.
        let title: String?
    }

    /// Install a virtual `.search` results tab from already-run hits — shared by ⌥F7/saved searches
    /// and by Recents.
    private func openResults(
        _ entries: [FileEntry],
        truncated: Bool,
        as presentation: ResultsPresentation
    ) {
        captureColumnLayout()
        let listing = DirectoryListing(
            path: VFSPath(backend: .search, path: "/" + presentation.pathSummary),
            entries: entries
        )
        // Show every hit, dotfiles included — a result the user explicitly asked for (a matched
        // search, or a recently-used file) shouldn't be hidden by the app-wide show-hidden toggle.
        let model = DirectoryModel(listing: listing, sort: presentation.sort, showHidden: true)
        let tab = PanelTab(panel: Panel(model: model))
        tab.hasLoaded = true
        tab.columnLayout = tabs[activeTabIndex].columnLayout
        // Retain what produced these results so "Save Search…" can persist it (nil for Recents).
        tab.searchQuery = presentation.query
        tab.searchScope = presentation.scope
        // A saved search / Recents names its results tab; an ad-hoc ⌥F7 search leaves the
        // query-summary chip.
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

    // MARK: - Saving the current search

    /// Whether the active results tab carries a re-runnable query — gates "Save Search…".
    var canSaveCurrentSearch: Bool {
        isSearchResults && tabs[activeTabIndex].searchQuery != nil
    }

    /// "Save Search…" — name the query behind the current results tab and store it as a saved
    /// search, so it appears in the sidebar's Searches section (PLAN.md §M4). Re-using an
    /// existing name updates that saved search in place after a replace confirmation.
    @objc func saveCurrentSearch(_ sender: Any?) {
        let tab = tabs[activeTabIndex]
        guard let query = tab.searchQuery else { return }
        guard let name = promptForSavedSearchName(default: query.summaryPlainName) else { return }

        var store = SavedSearchStore.load()
        if store.contains(name: name), !confirmReplaceSavedSearch(named: name) { return }
        store.save(SavedSearch(name: name, query: query, scope: tab.searchScope))
        SavedSearchStore.save(store)

        // Relabel the current results tab with the name the user just gave it.
        tab.customTitle = name
        refreshTabBar()
        persistState()
    }

    /// Ask for a saved-search name, prefilled with a sensible default, returning the trimmed
    /// non-empty result or `nil` on cancel / an empty name.
    private func promptForSavedSearchName(default defaultName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Search"
        alert.informativeText = "Give this search a name to keep it in the sidebar and re-run it later."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Search name"
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Confirm overwriting a saved search that already uses this name, so Save never silently
    /// clobbers one.
    private func confirmReplaceSavedSearch(named name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace “\(name)”?"
        alert.informativeText = "A saved search named “\(name)” already exists. Replace it?"
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
