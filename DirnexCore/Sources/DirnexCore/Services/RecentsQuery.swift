import Foundation

/// Finder's **Recents** as a query (PLAN.md §M8 "Recents row … Finder's is a saved search, and
/// saved searches already render into virtual result panels, so this reuses machinery instead of
/// adding some").
///
/// Recents is the recently-*used* files, everywhere indexed, which macOS records as
/// `kMDItemLastUsedDate` — the LaunchServices "last opened" stamp, distinct from the modification
/// date `SpotlightQuery.modifiedWithin` filters on. That distinction is the whole reason this is its
/// own tiny type rather than a `SpotlightQuery`: a cache file the system rewrites hourly has a fresh
/// *modification* date but is never *opened*, so a last-used filter is what keeps Recents to the
/// documents a person actually touched instead of a wall of `~/Library` churn (probed 2026-07-21:
/// the last-used filter returned 181 clean items, only two of them under `Library`).
///
/// Pure and testable like `SpotlightQuery`: this builds the `mdfind` predicate and argument vector
/// and touches no disk; the app runs `mdfind` with them off the main thread (`SpotlightSearchRunner`)
/// and stats the hits into a virtual results panel.
public struct RecentsQuery: Sendable, Equatable {
    /// The rolling window, in seconds back from now, an item must have been used within to count as
    /// recent. A bound is deliberate rather than "everything ever opened": `mdfind` cannot sort
    /// (there is no sort flag) and the runner keeps only its first N paths, so an unbounded query
    /// would surface an arbitrary N, not the newest N. A 30-day window keeps the set both meaningful
    /// and small enough to fall well under that cap.
    public var usedWithinSeconds: Int

    public init(usedWithinSeconds: Int = RecentsQuery.defaultWindowSeconds) {
        self.usedWithinSeconds = usedWithinSeconds
    }

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

    /// How the results are ordered once listed: modification date, newest first, folders *not*
    /// grouped ahead of files (recency is the whole ordering, not folders-then-files).
    ///
    /// This is a **proxy** for "last opened", chosen because it is the only recency signal the app
    /// can compute: `mdfind` returns paths in no useful order and offers no sort flag, and a statted
    /// `FileEntry` carries a modification date but not `kMDItemLastUsedDate`. For the documents a
    /// person is actively working on, used and modified move together, so the order is usually right;
    /// a file opened-but-not-edited (a watched video) sorts by when it was written instead. Bringing
    /// the true last-used date into the ordering is left to a later pass if it proves to matter.
    public static let resultSort = FileSort(
        key: .modified,
        ascending: false,
        directoriesFirst: false
    )

    /// The raw `mdfind` metadata predicate: used within the window, and not an application bundle.
    ///
    /// The window is expressed as a relative `$time.now(-seconds)` offset rather than a wall-clock
    /// literal, matching `SpotlightQuery`, so the string is deterministic and testable.
    public func metadataPredicate() -> String {
        "(kMDItemLastUsedDate >= $time.now(-\(usedWithinSeconds)))"
            + " && (kMDItemContentTypeTree != \"\(Self.excludedContentType)\")"
    }

    /// The full argument vector for `/usr/bin/mdfind`. No `-onlyin`: Recents searches everywhere
    /// indexed, like Finder's, rather than scoping to any one folder.
    public func mdfindArguments() -> [String] {
        [metadataPredicate()]
    }
}
