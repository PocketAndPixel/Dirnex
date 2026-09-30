import AppKit
import DirnexCore

/// ⌥F7 on a place with no index behind it — a connected server, or an archive (PLAN.md §M22).
///
/// Split from `PanelViewController+Search`, which owns the Spotlight route and the results tab both
/// routes land in. The seam is the one the milestone is about: *finding* the files differs, and
/// everything after that — the virtual tab, its entries' real paths, F5 and ⌘Y reaching them — is
/// the machinery that was already there and needed no changes at all.
extension PanelViewController {
    /// Walk `root`'s subtree for `query`, with a sheet showing progress and offering Stop, then
    /// install the hits as a results tab.
    ///
    /// `title` is the results tab's chip label — a saved search's name, exactly as the Spotlight
    /// route takes one. A fresh ⌥F7 leaves it `nil` and the chip shows the query summary.
    func performWalkSearch(_ query: FileQuery, under root: VFSPath, title: String? = nil) {
        let predicate: SearchPredicate
        let fields = SearchFields.answerable(by: root.backend)
        do {
            predicate = try SearchPredicate(query, answering: fields)
        } catch let unanswerable as SearchQueryUnanswerable {
            presentUnanswerable(unanswerable, at: root)
            return
        } catch {
            return
        }

        let backend = backend
        let control = SearchControl()
        let sheet = SearchProgressSheet(
            scopeName: root.displayName,
            control: control,
            window: view.window
        )
        sheet.start()

        Task {
            defer { sheet.finish() }
            do {
                let results = try await SubtreeSearchRunner.run(
                    predicate,
                    under: root,
                    backend: backend,
                    control: control
                )
                sheet.finish()
                install(results, query: query, scope: root, title: title)
            } catch {
                sheet.finish()
                presentOperationFailure(
                    message: String(
                        localized: "Couldn’t search “\(root.displayName)”",
                        comment: "Search failure title; %@ is the folder or server searched."
                    ),
                    detail: VFSErrorText.sentence(for: error)
                )
            }
        }
    }

    /// Install the hits, then say how the search ended if it did not simply finish.
    private func install(
        _ results: SubtreeSearch.Results,
        query: FileQuery,
        scope: VFSPath,
        title: String?
    ) {
        openResults(
            results.hits,
            // The shared truncation alert is the right words for exactly one of the three
            // completions; the other two get their own below.
            truncated: results.completion == .truncated,
            as: ResultsPresentation(
                pathSummary: LocalizedCatalog.summary(of: query),
                sort: panel.model.sort,
                query: query,
                scope: scope,
                title: title
            )
        )
        report(results.completion, hits: results.hits.count, listed: results.directoriesListed)
    }

    /// Three completions, three different things to say — and two different *surfaces*, which is the
    /// decision worth stating: a limit the user ran into is an alert, and a stop the user chose is
    /// not. Telling someone that the thing they just asked for happened is noise, but leaving a
    /// partial result set looking complete is worse, so it goes to the status line.
    private func report(_ completion: SubtreeSearch.Completion, hits: Int, listed: Int) {
        switch completion {
        case .complete, .truncated:
            break // nothing more to say; `openResults` raised the truncation alert
        case .stopped:
            showTransientStatus(
                String(
                    localized: "Search stopped · Found: \(hits)",
                    comment: """
                    Pane status line after the user stopped a search. %lld is how many matches had \
                    been found by then, all of which are shown.
                    """
                )
            )
        case .budgetExceeded:
            presentOperationFailure(
                message: String(
                    localized: "Search stopped early",
                    comment: "Search-budget title."
                ),
                detail: String(
                    localized: """
                    Every folder on a server is a separate request, so Dirnex stops after a while. \
                    Folders searched: \(listed). The matches found so far are shown — search a \
                    folder further in to cover the rest.
                    """,
                    comment: "Search-budget body; %lld is how many folders were searched."
                )
            )
        }
    }

    /// A saved search whose stored scope is somewhere with nothing to search — a results listing, or
    /// an S3 account pane whose rows are buckets (PLAN.md §M22 Slice 5).
    ///
    /// Not reachable from anything the app itself saves today: ⌥F7 resolves such a pane to a real
    /// directory before it offers the dialog, so what gets stored is that directory. It exists
    /// because the alternatives at an exhaustive `switch` are both worse — running Spotlight
    /// *everywhere* silently widens a search the user named, and returning in silence is a keystroke
    /// that does nothing, which this project has twice found to be the expensive kind of wrong.
    ///
    /// The title is keyed identically to ``presentUnanswerable(_:at:)``'s, comment included, so the
    /// two share one catalog entry rather than handing a translator whichever `xcstringstool` kept.
    func presentUnsearchableScope(at scope: VFSPath) {
        presentOperationFailure(
            message: String(
                localized: "Can’t run this search on “\(scope.displayName)”",
                comment: "Unanswerable-search title; %@ is the server or folder."
            ),
            detail: String(
                localized: """
                This saved search points at a place that can’t be searched. Open the folder or \
                server you want to search and start a new search there.
                """,
                comment: """
                Body shown when a saved search's stored scope has nothing to search — a results \
                listing, or an S3 account whose rows are buckets rather than files.
                """
            )
        )
    }

    /// A query asking for something this place cannot answer.
    ///
    /// Reachable from a *saved* search — the Find Files dialog hides the fields a scope cannot
    /// answer, so nothing typed there can produce this. The sentence names the term rather than
    /// merely refusing: a search that works perfectly at home and does nothing here reads as the
    /// feature being broken unless it says which half of the query is the problem.
    private func presentUnanswerable(_ error: SearchQueryUnanswerable, at root: VFSPath) {
        presentOperationFailure(
            message: String(
                localized: "Can’t run this search on “\(root.displayName)”",
                comment: "Unanswerable-search title; %@ is the server or folder."
            ),
            detail: Self.describe(error.fields)
        )
    }

    private static func describe(_ fields: SearchFields) -> String {
        let hasContent = fields.contains(.content)
        let hasTags = fields.contains(.tags)
        if hasContent, hasTags {
            return String(
                localized: """
                This search looks inside files and matches tags, and neither is available here — \
                only what a folder listing carries can be searched.
                """,
                comment: "Unanswerable-search body: both content and tags are out of reach."
            )
        }
        if hasContent {
            return String(
                localized: """
                This search looks inside files, which needs the Spotlight index and is only \
                available on this Mac.
                """,
                comment: "Unanswerable-search body: file contents are out of reach."
            )
        }
        return String(
            localized: """
            This search matches Finder tags, which only files on this Mac carry.
            """,
            comment: "Unanswerable-search body: Finder tags are out of reach."
        )
    }
}
