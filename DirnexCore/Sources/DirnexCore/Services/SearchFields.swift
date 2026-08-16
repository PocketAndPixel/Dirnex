import Foundation

/// Which of a ``FileQuery``'s clauses a given place can actually answer (PLAN.md §M22).
///
/// ⌥F7 was Spotlight-only until M22, so every field was answerable everywhere by construction and
/// nothing had to ask. A connected server has no index: what a listing hands over is a name, a size,
/// a date and enough of a name to guess a type from — and the *text inside* a file, or the Finder
/// tags on it, are simply not among them.
///
/// One named set rather than a check per site, which is this project's most-repeated finding in the
/// other direction: a question with several spellings is how a backend added later inherits the
/// wrong answer silently. Two very different things read it — the Find Files dialog, to decide which
/// rows to draw at all, and ``SearchPredicate``, to refuse a query asking for something it cannot
/// evaluate. Had those been two predicates, the failure would have been the quiet one: a saved
/// search carrying `contentContains`, re-run in a bucket by a matcher that skips the clause it
/// cannot answer, returns **more** results under the same name.
public struct SearchFields: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// A substring of the file's name.
    public static let name = SearchFields(rawValue: 1 << 0)
    /// A substring of the file's indexed *text*. Spotlight alone — reproducing it anywhere else
    /// means downloading everything under the scope in order to grep it.
    public static let content = SearchFields(rawValue: 1 << 1)
    /// Finder tags. Spotlight alone, and for a second reason beyond the index: a tag is an extended
    /// attribute of a local file, and nothing on a server carries one.
    public static let tags = SearchFields(rawValue: 1 << 2)
    /// The kind chips. Answerable off a listing too, but from the **name** rather than from the
    /// bytes — see ``SearchPredicate``.
    public static let kind = SearchFields(rawValue: 1 << 3)
    /// The minimum-size chip.
    public static let size = SearchFields(rawValue: 1 << 4)
    /// The modified-within chip.
    public static let modified = SearchFields(rawValue: 1 << 5)

    /// Everything — what a Spotlight-indexed search answers.
    public static let indexed: SearchFields = [.name, .content, .tags, .kind, .size, .modified]

    /// What an ordinary directory listing carries, and therefore what a walk over one can decide:
    /// name, kind, size, date. This is the remote set, and its two absences are the whole of what
    /// the Find Files dialog hides when the pane is on a server.
    public static let listed: SearchFields = [.name, .kind, .size, .modified]

    /// The fields a search scoped inside `backend` can answer.
    ///
    /// Keyed on ``VFSBackendID/isRemoteConnection`` and ``VFSBackendID/isArchive`` rather than on a
    /// list of cases, for the reason ``DirectorySizeBudget/forBackend(_:)`` is: a fourth remote
    /// backend must inherit the right answer rather than a comparison somebody has to find. A
    /// backend this does not recognize answers ``indexed`` **only** when it is `.local`; everything
    /// else gets the listing set, which is the safe direction — it withholds a clause rather than
    /// promising one that is never applied.
    public static func answerable(by backend: VFSBackendID) -> SearchFields {
        backend == .local ? .indexed : .listed
    }
}

/// How a search under a given scope is actually run (PLAN.md §M22).
///
/// The route is a property of the *scope's* backend, not of the pane: a results tab, the merged
/// Trash and iCloud Drive have no directory of their own, so the app resolves such a pane's scope to
/// a real directory before it asks — which is why the virtual containers are ``unavailable`` here
/// rather than quietly mapped onto Spotlight.
public enum SearchRoute: Sendable, Equatable {
    /// `mdfind` against the local index — the only route that can answer content and tags.
    case spotlight
    /// A recursive walk of the backend's own listings, matching each entry as it arrives. What a
    /// connected server and an archive get.
    case walk
    /// Not searchable. An **S3 account** pane is the case that matters: its rows are buckets, and
    /// "search every bucket" is a different and far more expensive question than the one ⌥F7 asks.
    case unavailable

    /// The route **re-running a saved search** takes (PLAN.md §M22 Slice 5).
    ///
    /// A saved search is the one place where the scope, rather than the pane, is the only thing that
    /// says where a search runs — it carries an absolute path from whenever it was saved and does
    /// not follow the pane. So it needs the same routing decision, and inheriting Spotlight's by
    /// default is what went wrong: an `mdfind` scope is a bare *path*, with no backend in it, so a
    /// search saved at a bucket or archive **root** re-ran as `-onlyin /` over the whole local disk
    /// (measured — see `PanelViewController.runSavedSearch`).
    ///
    /// No scope means Spotlight's "everywhere", which is the *absence* of a place rather than a
    /// place. Nothing else has an everywhere: a walk needs a root to start at.
    public static func forSavedSearch(_ savedSearch: SavedSearch) -> SearchRoute {
        guard let scope = savedSearch.scope else { return .spotlight }
        return forBackend(scope.backend)
    }

    /// The route a search scoped inside `backend` takes.
    public static func forBackend(_ backend: VFSBackendID) -> SearchRoute {
        if backend == .local { return .spotlight }
        // Ahead of `isRemoteConnection`, which an account is a member of — this is the one remote
        // backend that is browsable and not searchable, the same asymmetry `acceptsUploads` records.
        if backend.isS3Account { return .unavailable }
        if backend.isRemoteConnection || backend.isArchive { return .walk }
        return .unavailable
    }
}
