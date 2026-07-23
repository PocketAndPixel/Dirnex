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
                    // Stable English identity, not display: the path bar self-names off it
                    // (`rebuildVirtualLabel`) and the tab title below localizes — the same split the
                    // Trash makes.
                    pathSummary: ResultsPresentation.recentsIdentity,
                    sort: RecentsQuery.resultSort,
                    query: nil,
                    scope: nil,
                    title: String(
                        localized: "Recents",
                        comment: "Tab title for the Recents listing."
                    )
                )
            )
        }
    }

    // MARK: - Virtual results tab

    /// Install the hits as a virtual results tab (`PanelViewController+Results`), labelled by the
    /// query that produced them and carrying it so "Save Search…" can persist it.
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
        alert.messageText = String(
            localized: "Save Search",
            comment: "Title of the save-search dialog."
        )
        alert.informativeText = String(
            localized: "Give this search a name to keep it in the sidebar and re-run it later.",
            comment: "Save-search dialog body."
        )
        alert.addButton(
            withTitle: String(localized: "Save", comment: "Button that saves the search.")
        )
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button that dismisses a dialog.")
        )

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(
            localized: "Search name",
            comment: "Placeholder in the save-search name field."
        )
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
        alert.messageText = String(
            localized: "Replace “\(name)”?",
            comment: "Save-search overwrite confirmation title; %@ is the saved-search name."
        )
        alert.informativeText = String(
            localized: "A saved search named “\(name)” already exists. Replace it?",
            comment: "Save-search overwrite confirmation body; %@ is the saved-search name."
        )
        alert.addButton(
            withTitle: String(
                localized: "Replace",
                comment: "Button that overwrites the existing item."
            )
        )
        alert.addButton(
            withTitle: String(localized: "Cancel", comment: "Button that dismisses a dialog.")
        )
        return alert.runModal() == .alertFirstButtonReturn
    }
}
