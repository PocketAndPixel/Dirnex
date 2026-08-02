import Foundation

/// One row of the tree view: a directory entry plus how deep it sits (PLAN.md §M15 Slice 4).
///
/// `depth` is 0 for the entries of the directory the tree is rooted at, 1 for the children of an
/// expanded root-level folder, and so on. The app turns it into leading indentation and a disclosure
/// arrow; the projection itself only counts levels.
public struct TreeRow: Sendable, Hashable {
    public let entry: FileEntry
    public let depth: Int

    public init(entry: FileEntry, depth: Int) {
        self.entry = entry
        self.depth = depth
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
    /// Type-to-filter text, applied per level exactly as the flat model applies it — so a filter can
    /// empty a level: a folder whose children all filter out still shows (if it matches at its own
    /// level) as an expanded row with nothing beneath it.
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

    /// The flattened, depth-annotated rows the pane renders — the tree's analogue of
    /// `DirectoryModel.visibleEntries`, and a stable array to index into.
    public private(set) var rows: [TreeRow]

    public init(
        rootPath: VFSPath,
        sort: FileSort = .default,
        showHidden: Bool = false,
        filter: String = "",
        expanded: Set<VFSPath> = []
    ) {
        self.rootPath = rootPath
        self.sort = sort
        self.showHidden = showHidden
        self.filter = filter
        self.expanded = expanded
        listings = [:]
        rows = []
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

    // MARK: - Flattening

    private mutating func rebuild() {
        var result: [TreeRow] = []
        appendLevel(of: rootPath, depth: 0, into: &result)
        rows = result
    }

    /// Project one directory's entries through a `DirectoryModel` — so ordering, the hidden filter and
    /// the text filter are byte-for-byte the flat model's — emit a row per visible entry, and recurse
    /// into each that is an expanded directory. Depth-first, children right after their parent.
    ///
    /// Termination: every recursion descends into a strictly-deeper child path, and there are finitely
    /// many `listings` keys, each the parent of its own entries exactly once — so no directory is
    /// visited twice and the walk is bounded by the listings held, even if a symlink points back up
    /// the tree (its listing is keyed by the *link's* path, distinct from any ancestor's).
    private func appendLevel(of directory: VFSPath, depth: Int, into result: inout [TreeRow]) {
        guard let rawEntries = listings[directory] else { return }
        let model = DirectoryModel(
            listing: DirectoryListing(path: directory, entries: rawEntries),
            sort: sort,
            showHidden: showHidden,
            filter: filter
        )
        for entry in model.visibleEntries {
            result.append(TreeRow(entry: entry, depth: depth))
            if entry.isDirectoryLike, expanded.contains(entry.path) {
                appendLevel(of: entry.path, depth: depth + 1, into: &result)
            }
        }
    }
}
