import AppKit
import DirnexCore

/// Spotlight file search (⌥F7 / palette "Find Files…") — PLAN.md §M4 "Search (Alt+F7 / palette):
/// mdfind-backed name+content search" and "Search results → virtual panel listing".
///
/// The pane presents the `SearchController` sheet, runs the resulting `FileQuery` through
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
        guard let scope = searchScopeDirectory() else { return }
        let controller = SearchController(
            currentFolderName: scope.displayName,
            fields: SearchFields.answerable(by: scope.backend),
            // The second scope option is "everywhere Spotlight indexed" locally and "everything on
            // this server" on a walk, which is the connection's own root — there being no index to
            // search and nowhere else to look.
            connectionRootTitle: SearchRoute.forBackend(scope.backend) == .walk
                ? scope.backendRootTitle
                : nil
        )
        controller.onSearch = { [weak self] query, choice in
            self?.runSearch(query, from: scope, choice: choice)
        }
        presentAsMovableWindow(controller)
    }

    /// Whether this pane has anything to search — gates ⌥F7 and its menu item.
    var canFindFiles: Bool {
        searchScopeDirectory() != nil
    }

    // MARK: - Running the search

    /// The real directory a "This Folder" search scopes to, or `nil` when this pane has nowhere to
    /// search at all.
    ///
    /// Two different fallbacks hide behind that `nil`, which is why the question is asked through
    /// `SearchRoute` rather than by testing the backend here. A **virtual results listing** — search
    /// hits, the merged Trash, iCloud Drive — has no directory of its own, but its rows are ordinary
    /// local files, so Home is a sensible place to point at. An **S3 account** pane has no such
    /// fallback: its rows are buckets, and quietly searching this Mac's home folder because the pane
    /// showed a list of buckets would answer a question nobody asked.
    private func searchScopeDirectory() -> VFSPath? {
        switch SearchRoute.forBackend(panel.path.backend) {
        case .spotlight, .walk:
            return panel.path
        case .unavailable:
            return panel.path.backend.isRemoteConnection ? nil : .local(NSHomeDirectory())
        }
    }

    private func runSearch(_ query: FileQuery, from scope: VFSPath, choice: SearchController.Scope) {
        switch SearchRoute.forBackend(scope.backend) {
        case .spotlight:
            performSearch(query, scope: choice == .currentFolder ? scope : nil)
        case .walk:
            // "Everything here" is the connection's or archive's own root, which is a real listable
            // path — unlike Spotlight's "everywhere", which is the absence of a scope.
            let root = choice == .currentFolder ? scope : VFSPath(backend: scope.backend, path: "/")
            performWalkSearch(query, under: root)
        case .unavailable:
            break // unreachable: `searchScopeDirectory` already refused
        }
    }

    /// Re-run a saved search from the sidebar (PLAN.md §M4 "Saved searches … in the places
    /// strip"). Unlike ⌥F7, its scope is the absolute path stored with the search — it doesn't
    /// follow the pane's current directory — so a "Pictures" saved search always searches
    /// Pictures wherever you invoke it.
    ///
    /// **Routed by the stored scope's backend, exactly as ⌥F7 routes by the pane's** (PLAN.md §M22
    /// Slice 5) — and it has to be, because the scope is the *only* thing that says where this
    /// search runs.
    ///
    /// Handing a bucket or an archive to the Spotlight route is not an error, and what it *is* was
    /// measured rather than guessed, because `FileQuery.mdfindArguments` takes `scope.path` and
    /// discards the backend. A scope at a **backend root** — every archive root, every bucket root,
    /// every server home — spells `path` as `"/"`, so it ran `mdfind -onlyin /`: the whole of this
    /// Mac. Verified live 2026-08-16 by reverting this function, where "Zip reports" — a search
    /// saved inside a four-file zip — came back with **1275 hits** from `/System`, `/Library` and
    /// the crash logs, in a tab wearing the name the user gave it. A scope one level down
    /// (`/2026`, `/docs`) answers **zero** instead. Both are the quiet direction and the first is
    /// the worse one: an empty pane at least looks like an answer about nothing, where a full one
    /// looks like an answer about the thing you asked for.
    func runSavedSearch(_ savedSearch: SavedSearch) {
        switch SearchRoute.forSavedSearch(savedSearch) {
        case .spotlight:
            // A saved search carries a friendly name — label its results tab with it, not the query.
            // A `nil` scope routes here and stays `nil`: that is Spotlight's "everywhere".
            performSearch(savedSearch.query, scope: savedSearch.scope, title: savedSearch.name)
        case .walk:
            // Non-`nil` by construction — only a scope can route here, since a walk needs a root.
            guard let scope = savedSearch.scope else { return }
            performWalkSearch(savedSearch.query, under: scope, title: savedSearch.name)
        case .unavailable:
            guard let scope = savedSearch.scope else { return }
            presentUnsearchableScope(at: scope)
        }
    }

    /// Find every file carrying `tag`, from the sidebar's Tags section (PLAN.md §M6 "Finder tags:
    /// … filter chips in search").
    ///
    /// Searches **everywhere**, like Finder's sidebar tags and unlike ⌥F7's "This Folder" — a tag is
    /// a thing you put on files so you can find them again wherever you left them, so scoping it to
    /// whatever folder happens to be open would defeat the point of having tagged them.
    ///
    /// Matched by name only, because a name is all Spotlight indexes (`FileQuery.tags`) — which
    /// costs nothing here, since a tag *is* its name to macOS and the color is only how it is drawn.
    func runTagSearch(_ tag: FinderTag) {
        performSearch(FileQuery(tags: [tag.name]), scope: nil, title: tag.name)
    }

    /// Run `query` within `scope` (its subtree), or everywhere when `scope` is `nil`, off the
    /// main thread, then install the hits as a virtual results tab. `title`, when given, is the
    /// tab's chip label (a saved search's name); a fresh ⌥F7 search leaves it `nil` and the chip
    /// shows the query summary.
    private func performSearch(_ query: FileQuery, scope: VFSPath?, title: String? = nil) {
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

    /// Install the hits as a virtual results tab (`PanelViewController+Results`), labeled by the
    /// query that produced them and carrying it so "Save Search…" can persist it.
    private func openSearchResults(
        _ entries: [FileEntry],
        query: FileQuery,
        scope: VFSPath?,
        truncated: Bool,
        title: String? = nil
    ) {
        openResults(
            entries,
            truncated: truncated,
            as: ResultsPresentation(
                pathSummary: LocalizedCatalog.summary(of: query),
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
        let prefill = LocalizedCatalog.plainName(of: query)
        // The prompts are sheets, so they are awaited rather than run inline; the work either side
        // of them is unchanged and still main-actor.
        Task { @MainActor in
            guard let name = await promptForSavedSearchName(default: prefill) else { return }

            var store = SavedSearchStore.load()
            if store.contains(name: name), await !confirmReplaceSavedSearch(named: name) { return }
            store.save(SavedSearch(name: name, query: query, scope: tab.searchScope))
            SavedSearchStore.save(store)

            // Relabel the current results tab with the name the user just gave it.
            tab.customTitle = name
            refreshTabBar()
            persistState()
        }
    }

    /// Ask for a saved-search name, prefilled with a sensible default, returning the trimmed
    /// non-empty result or `nil` on cancel / an empty name.
    private func promptForSavedSearchName(default defaultName: String) async -> String? {
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
        alert.enableEscapeToCancel()

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.keepToOneLine()
        field.placeholderString = String(
            localized: "Search name",
            comment: "Placeholder in the save-search name field."
        )
        field.stringValue = defaultName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = await alert.runSheet(over: view.window) { field.selectText(nil) }
        guard response == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Confirm overwriting a saved search that already uses this name, so Save never silently
    /// clobbers one.
    private func confirmReplaceSavedSearch(named name: String) async -> Bool {
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
        alert.enableEscapeToCancel()
        return await alert.runSheet(over: view.window) == .alertFirstButtonReturn
    }
}
