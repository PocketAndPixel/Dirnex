import Foundation

/// Finder's **Recents** as a query (PLAN.md §M8 "Recents row … Finder's is a saved search, and
/// saved searches already render into virtual result panels, so this reuses machinery instead of
/// adding some").
///
/// Recents is the recently-*used* files, everywhere indexed, which macOS records as
/// `kMDItemLastUsedDate` — the LaunchServices "last opened" stamp, distinct from the modification
/// date `FileQuery.modifiedWithin` filters on. That distinction is the whole reason this is its
/// own tiny type rather than a `FileQuery`: a cache file the system rewrites hourly has a fresh
/// *modification* date but is never *opened*, so a last-used filter is what keeps Recents to the
/// documents a person actually touched instead of a wall of `~/Library` churn (probed 2026-07-21:
/// the last-used filter returned 181 clean items, only two of them under `Library`).
///
/// Pure and testable like `FileQuery`: this builds the `mdfind` predicate and argument vector
/// and touches no disk; the app runs `mdfind` with them off the main thread (`SpotlightSearchRunner`),
/// and ``RecentsQuery/hits(fromOutput:)`` and ``RecentsListing`` turn what it printed into the rows of
/// a virtual results panel.
public struct RecentsQuery: Sendable, Equatable {
    /// The rolling window, in seconds back from now, an item must have been used within to count as
    /// recent. A bound is deliberate rather than "everything ever opened": the listing keeps only the
    /// newest N (``RecentsListing``), so an unbounded query would read and sort every file ever opened
    /// to show the same N. A 30-day window keeps the set both meaningful and small enough to fall
    /// well under that cap (50 hits on the development Mac, 2026-11-18).
    public var usedWithinSeconds: Int

    public init(usedWithinSeconds: Int = RecentsQuery.defaultWindowSeconds) {
        self.usedWithinSeconds = usedWithinSeconds
    }

    /// The name the Recents results tab is filed under — the last component of its synthetic
    /// `search:` path. A stable English identity, never displayed: the tab title and the path bar
    /// localize on their own, and the sidebar recognizes the tab by it
    /// (``SidebarPlaceLocator/recentsPath``).
    public static let listingName = "Recents"

    /// 30 days. Not exact-calendar (a month is 30 days here, as in `SearchAge`); exactness doesn't
    /// matter for a "recently used" cutoff.
    public static let defaultWindowSeconds = 30 * 24 * 60 * 60

    /// The content type excluded from the results: application bundles. A Recents that opened with a
    /// stack of `.app`s — every app you launched this month is "recently used" to Spotlight — reads
    /// as noise, not as the documents Recents is for (probed: without this exclusion the list led
    /// with Console.app, Terminal.app, Finder.app). Folders are *not* excluded: a recently-used
    /// folder is a legitimate navigation target in a file manager, and excluding `public.folder`
    /// also risks dropping document packages that conform to it.
    static let excludedContentType = "com.apple.application-bundle"

    /// The attribute `mdfind` prints beside each path: the date the item was last opened, which is
    /// what Recents lists by (PLAN.md §M40 Slice 2).
    static let lastUsedAttribute = "kMDItemLastUsedDate"

    /// How the results are ordered once listed: by the Date column, newest first, folders *not*
    /// grouped ahead of files (recency is the whole ordering, not folders-then-files).
    ///
    /// In Recents the Date column holds when each item was last opened (``ListingDate``), so this
    /// is the true "last opened" order (PLAN.md §M40 Slice 2). Until then it was the modification
    /// date standing in, since `mdfind` returns paths in no useful order and a `stat` carries no
    /// last-opened date; a file opened and not edited, such as a watched video, sorted by when it
    /// was written. The date now comes in the same `mdfind` call (``mdfindArguments()``).
    public static let resultSort = FileSort(
        key: .modified,
        ascending: false,
        directoriesFirst: false
    )

    /// The raw `mdfind` metadata predicate: used within the window, and not an application bundle.
    ///
    /// The window is expressed as a relative `$time.now(-seconds)` offset rather than a wall-clock
    /// literal, matching `FileQuery`, so the string is deterministic and testable.
    public func metadataPredicate() -> String {
        "(kMDItemLastUsedDate >= $time.now(-\(usedWithinSeconds)))"
            + " && (kMDItemContentTypeTree != \"\(Self.excludedContentType)\")"
    }

    /// The full argument vector for `/usr/bin/mdfind`. No `-onlyin`: Recents searches everywhere
    /// indexed, like Finder's, rather than scoping to any one folder.
    ///
    /// `-attr` prints each hit's last-opened date after its path, in the same call, and `-0` ends
    /// each record with a NUL rather than a newline, so a name holding a newline stays one record
    /// (both probed 2026-11-18; ``RecentsQuery/hits(fromOutput:)`` reads the result).
    public func mdfindArguments() -> [String] {
        ["-0", "-attr", Self.lastUsedAttribute, metadataPredicate()]
    }
}
