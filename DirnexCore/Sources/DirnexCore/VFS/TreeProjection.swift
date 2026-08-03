import Foundation

/// One row of the tree view: a directory entry plus how deep it sits (PLAN.md §M15 Slice 4).
///
/// `depth` is 0 for the entries of the directory the tree is rooted at, 1 for the children of an
/// expanded root-level folder, and so on. The app turns it into leading indentation and a disclosure
/// arrow; the projection itself only counts levels.
public struct TreeRow: Sendable, Hashable {
    public let entry: FileEntry
    public let depth: Int

    /// Whether this row matched the filter *itself*, as opposed to being drawn only because a
    /// descendant did (see `TreeProjection.appendLevel`). Always `true` when no filter is active, so
    /// a caller counting matches gets the row count for free in the ordinary case.
    ///
    /// It exists because "how many things did I find" and "how many rows are on screen" stop being
    /// the same number the moment a folder is kept as scaffolding — and the first is what a user
    /// reading a filtered pane is asking. Marking, sizing and every file operation still work on the
    /// row, scaffolding included: this narrows what is *reported*, never what is *addressed*.
    public let matchesFilter: Bool

    public init(entry: FileEntry, depth: Int, matchesFilter: Bool = true) {
        self.entry = entry
        self.depth = depth
        self.matchesFilter = matchesFilter
    }
}

/// A pure flattening of a set of expanded directories into one indexed row list — the tree view's
/// model (PLAN.md §M15 Slice 4).
///
/// The whole design bet of the slice is that a tree is **not a second surface**: it is the same flat
/// `NSTableView` over the same `VFSPath` index space the list already uses (HISTORY.md §M8, the
/// sidebar's shape — "every row is a leaf, so folding is a build-time filter, not a view feature").
/// So this type produces exactly what the flat `DirectoryModel` produces — a stable array of rows to
/// index into, sorted and filtered the same way — only spanning several directories instead of one.
///
/// It **reuses `DirectoryModel` per level** rather than re-deriving sort/hidden/filter: each
/// directory's raw entries are projected through a `DirectoryModel` and the results stitched together
/// depth-first, an expanded folder's children inserted right after it. That is deliberate, and the
/// risk table (§6) names why — a sort, a filter or a hidden-toggle that behaved differently in the
/// tree than in the list would be a *fork*, which means the projection is wrong, not that the tree
/// needs its own copy. There is no second definition of "how a level is ordered" to drift.
///
/// A consequence worth stating: with nothing expanded, the depth-0 rows are the flat model's rows
/// byte-for-byte, so an all-collapsed tree renders identically to the list.
///
/// Everything is pure and synchronous: listing a directory is the caller's async I/O, handed in via
/// `setListing`. Expansion state and the per-directory listings live here so the row list can be
/// re-materialized whenever any input changes, exactly as `DirectoryModel.visibleEntries` is.
public struct TreeProjection: Sendable {
    /// The directory the tree is rooted at — its entries are the depth-0 rows.
    public let rootPath: VFSPath

    public var sort: FileSort { didSet { rebuild() } }
    public var showHidden: Bool { didSet { rebuild() } }
    /// Type-to-filter text, matched per level exactly as the flat model matches it, with one rule of
    /// the tree's own: an expanded folder also survives when a **descendant** matches, so the filter
    /// reaches into the folders the user has opened instead of hiding them for their own names. See
    /// `appendLevel` for why, and for what that costs. Two consequences worth stating: a folder whose
    /// children all filter out still shows (if it matches at its own level) as an expanded row with
    /// nothing beneath it, and a folder shown purely as scaffolding is an ordinary row — it can be
    /// marked, and marking it means the whole folder, non-matching children included, exactly as
    /// marking a filtered-in folder does in the flat list.
    public var filter: String { didSet { rebuild() } }

    /// Directories the user has opened, by identity. A path stays here while an ancestor is collapsed
    /// — collapsing hides a subtree without forgetting how it was arranged, so re-expanding the
    /// ancestor brings the whole sub-tree back (Finder/Total Commander behaviour). A path with no
    /// listing yet renders as a childless expanded folder until its `setListing` arrives — the
    /// lazy-load window.
    public private(set) var expanded: Set<VFSPath>

    /// Raw, unsorted entries per directory, keyed by the directory's path — the root plus every
    /// directory that has been listed. Kept unsorted so a sort change re-orders from the same source
    /// rather than re-sorting an already-sorted list, matching `DirectoryModel`, which sorts the raw
    /// `listing.entries` each time.
    private var listings: [VFSPath: [FileEntry]]

    /// Recursively-computed directory totals, keyed by the sized directory's path — spanning every
    /// level, the tree's analogue of `DirectoryModel.directorySizes`. One flat map covers the whole
    /// tree because a `VFSPath` is unique, and each level's `DirectoryModel` is handed the map and
    /// prunes it to its own entries, so a size-sort orders each level on live totals exactly as the
    /// flat list does. The app fills this from its `DirectorySizeProvider` (Space-on-dir or the
    /// size-visualization scan); a size for an entry no level lists is inert until it does.
    public private(set) var directorySizes: [VFSPath: Int64]

    /// The flattened, depth-annotated rows the pane renders — the tree's analogue of
    /// `DirectoryModel.visibleEntries`, and a stable array to index into.
    public private(set) var rows: [TreeRow]

    /// How many rows matched the filter themselves — `rows.count` minus the folders kept only as the
    /// path to a match. Equal to `count` whenever no filter is active, and never larger.
    ///
    /// Stored rather than computed so the status line, which is rebuilt on every render, stays O(1)
    /// on a pane that can hold 100k rows; the flatten is already walking them, so it costs nothing.
    public private(set) var matchCount: Int

    public init(
        rootPath: VFSPath,
        sort: FileSort = .default,
        showHidden: Bool = false,
        filter: String = "",
        expanded: Set<VFSPath> = [],
        directorySizes: [VFSPath: Int64] = [:]
    ) {
        self.rootPath = rootPath
        self.sort = sort
        self.showHidden = showHidden
        self.filter = filter
        self.expanded = expanded
        self.directorySizes = directorySizes
        listings = [:]
        rows = []
        matchCount = 0
        // No rebuild: with no listings the row list is empty, which is the correct initial state.
        // (didSet does not fire during init, so nothing would run anyway.)
    }

    // MARK: - Accessors (mirroring DirectoryModel)

    public var count: Int { rows.count }
    public var isEmpty: Bool { rows.isEmpty }
    public subscript(index: Int) -> TreeRow { rows[index] }

    /// The entry at a row index, or `nil` when the index is out of range.
    public func entry(at index: Int) -> FileEntry? {
        index >= 0 && index < rows.count ? rows[index].entry : nil
    }

    /// Row index of a specific entry, or `nil` if it is not currently visible. A `VFSPath` appears at
    /// most once in the tree — each path has exactly one parent — so this is unambiguous.
    public func index(ofID id: VFSPath) -> Int? {
        rows.firstIndex { $0.entry.id == id }
    }

    /// Whether `path` is in the expanded set. This is membership, not reachability: an expanded folder
    /// nested inside a collapsed one is still "expanded" here (so re-opening the ancestor restores it)
    /// even though it currently renders no rows.
    public func isExpanded(_ path: VFSPath) -> Bool {
        expanded.contains(path)
    }

    /// Whether a directory's children have been listed yet (the root included).
    public func hasListing(for path: VFSPath) -> Bool {
        listings[path] != nil
    }

    /// A listed directory's raw entries (unsorted, unfiltered, hidden included), or `nil` if that
    /// directory has not been listed. The raw set is what a bystander check wants — a hidden or
    /// filtered-out file still collides on disk — mirroring how the flat model checks against
    /// `listing.entries` rather than `visibleEntries`.
    public func entries(in directory: VFSPath) -> [FileEntry]? {
        listings[directory]
    }

    /// A row's recursively-computed total, or `nil` if it has none yet — the tree's analogue of
    /// `DirectoryModel.computedSize`, reading the flat cross-level `directorySizes` map.
    public func computedSize(of entry: FileEntry) -> Int64? {
        directorySizes[entry.id]
    }

    /// Every directory the tree currently holds a listing for — the root plus each expanded folder
    /// that has been lazily loaded. The app watches exactly this set with one FSEvents stream (one
    /// per folder would be wasteful — PLAN.md §M15 Slice 4) and re-lists each of them when a change
    /// lands, since the event carries no path (`DirectoryWatcher` discards it). Unordered, like the
    /// dictionary it reads.
    public var listedDirectories: [VFSPath] {
        Array(listings.keys)
    }

    /// Every entry the tree holds a listing for, across all levels — the set a refresh prunes marks
    /// against, so a mark on an entry in one expanded folder survives another folder's refresh. This
    /// **includes** entries hidden or filtered out of `rows` (they still exist in the directory),
    /// mirroring how the flat model prunes to `listing.entries` rather than to `visibleEntries`.
    public var allEntryIDs: Set<VFSPath> {
        var ids = Set<VFSPath>()
        for entries in listings.values {
            for entry in entries { ids.insert(entry.id) }
        }
        return ids
    }

    // MARK: - Mutation

    /// Install or replace a directory's raw entries — the root's first load, an expanded child's lazy
    /// load, or an FSEvents refresh of either. Rebuilds the row list.
    public mutating func setListing(_ path: VFSPath, entries: [FileEntry]) {
        listings[path] = entries
        rebuild()
    }

    /// Forget a directory's cached entries — e.g. pruning a collapsed subtree the app no longer wants
    /// to hold. Rebuilds only if there was one to remove.
    public mutating func removeListing(_ path: VFSPath) {
        guard listings.removeValue(forKey: path) != nil else { return }
        rebuild()
    }

    /// Mark a directory open (the `→` key on a closed folder). Beyond membership this shows nothing
    /// until the directory's listing arrives.
    public mutating func expand(_ path: VFSPath) {
        guard !expanded.contains(path) else { return }
        expanded.insert(path)
        rebuild()
    }

    /// Mark a directory closed (the `←` key on an open folder), keeping any descendant expansion for
    /// when it re-opens.
    public mutating func collapse(_ path: VFSPath) {
        guard expanded.contains(path) else { return }
        expanded.remove(path)
        rebuild()
    }

    /// Record recursively-computed totals for directory rows at any level — the size-visualization
    /// scan landing, or Space-on-dir — re-flattening so a size-sort re-orders and the bars re-scale.
    /// Existing totals for unmentioned paths are kept; a repeated path takes the new value. A no-op
    /// for an empty batch, so a cold seed does not rebuild for nothing (`DirectoryModel` guards the
    /// same way, and for the same reason).
    public mutating func setDirectorySizes(_ sizes: [VFSPath: Int64]) {
        guard !sizes.isEmpty else { return }
        directorySizes.merge(sizes) { _, new in new }
        rebuild()
    }

    /// Forget every computed total — the `.gitignore`-aware rule being switched, or its rules moving
    /// underneath the mode (the distinction `DirectoryModel.clearDirectorySizes` documents). Rebuilds
    /// only if there was something to drop.
    public mutating func clearDirectorySizes() {
        guard !directorySizes.isEmpty else { return }
        directorySizes = [:]
        rebuild()
    }

    // MARK: - Flattening

    private mutating func rebuild() {
        var result: [TreeRow] = []
        appendLevel(of: rootPath, depth: 0, into: &result)
        rows = result
        // Tallied from the finished rows rather than during the walk: `appendLevel` speculatively
        // emits a folder and takes it back when nothing beneath it survived, so a running count kept
        // alongside would have to be unwound in step with the `removeLast` — one more thing to get
        // out of agreement with what is on screen. Counting what actually shipped cannot drift.
        matchCount = result.count { $0.matchesFilter }
    }

    /// Project one directory's entries through a `DirectoryModel` — so ordering, the hidden filter and
    /// the text filter are byte-for-byte the flat model's — emit a row per surviving entry, and recurse
    /// into each that is an expanded directory. Depth-first, children right after their parent.
    ///
    /// "Surviving" is where a tree differs from a list, and it is the one rule this type adds on top of
    /// `DirectoryModel`: an entry survives if it **matches the filter itself, or if anything beneath it
    /// does**. A folder is the path to its contents, so filtering it out for its own name would take
    /// every match inside it off screen — which made the filter unusable in a tree, since the useful
    /// query ("where is `report`") almost never matches the folders on the way to it. A non-matching
    /// ancestor is therefore kept as scaffolding, exactly as it is in every outline filter.
    ///
    /// Only *expanded* folders can rescue an ancestor: this stays a pure projection of the listings
    /// already in hand, so a collapsed folder contributes no rows and rescues nothing, whether or not
    /// its listing happens to be cached. Reaching into unlisted directories would make a keystroke do
    /// I/O — that is search (⌘F), not a filter.
    ///
    /// Termination: every recursion descends into a strictly-deeper child path, and there are finitely
    /// many `listings` keys, each the parent of its own entries exactly once — so no directory is
    /// visited twice and the walk is bounded by the listings held, even if a symlink points back up
    /// the tree (its listing is keyed by the *link's* path, distinct from any ancestor's).
    private func appendLevel(of directory: VFSPath, depth: Int, into result: inout [TreeRow]) {
        guard let rawEntries = listings[directory] else { return }
        // The whole cross-level map is handed to every level; the size-aware initializer prunes it to
        // this directory's own entries (exactly as `updateListing` prunes on refresh), so a size-sort
        // orders each level on its own live totals and no other level's number can leak in.
        let model = DirectoryModel(
            listing: DirectoryListing(path: directory, entries: rawEntries),
            sort: sort,
            showHidden: showHidden,
            filter: filter,
            directorySizes: directorySizes
        )
        // `visibleEntries` (matched the text filter) is an order-preserving subset of `sortedEntries`
        // (the level under `sort` + `showHidden`) — `DirectoryModel` splits its projection in exactly
        // those two stages — so one forward index decides "did this entry match" with no set to build.
        // Worth the care: this runs per level on every keystroke.
        let matches = model.visibleEntries
        var matchIndex = 0
        for entry in model.sortedEntries {
            var isMatch = false
            if matchIndex < matches.count, matches[matchIndex].id == entry.id {
                isMatch = true
                matchIndex += 1
            }
            guard entry.isDirectoryLike, expanded.contains(entry.path) else {
                if isMatch { result.append(TreeRow(entry: entry, depth: depth)) }
                continue
            }
            // Speculatively emit the folder, walk it, and take it back if it turned out to be neither
            // a match nor the way to one. Cheaper than building the subtree in a scratch array, and it
            // keeps the depth-first order the rows are read in.
            let mark = result.count
            result.append(TreeRow(entry: entry, depth: depth, matchesFilter: isMatch))
            appendLevel(of: entry.path, depth: depth + 1, into: &result)
            if !isMatch, result.count == mark + 1 { result.removeLast() }
        }
    }
}
