import Foundation

/// The headless brain of a single pane: what directory it shows, where the cursor
/// is, and which entries are marked. The AppKit view is a thin renderer over this
/// (PLAN.md §2 "UI is a thin client").
///
/// Everything here is pure and synchronous — disk I/O (listing a directory) happens
/// in the caller via a `VFSBackend`, and the resulting `DirectoryListing` is handed
/// to `setListing`. That keeps the whole selection/cursor/navigation model unit
/// testable without touching the filesystem.
///
/// Two invariants this type maintains, both from the plan:
/// - **Selection is independent of the cursor** (PLAN.md §1): marking never moves
///   the cursor unless you ask it to, and moving the cursor never changes marks.
/// - **Cursor survives a live refresh by identity, not row index** (PLAN.md §6): a
///   same-directory `setListing` re-anchors the cursor on the same file if it is
///   still present.
public struct Panel: Sendable {
    public private(set) var model: DirectoryModel
    /// Index into `model.visibleEntries`. Clamped to a valid row, or 0 when empty.
    public private(set) var cursor: Int
    /// Marked entries, keyed by their stable path identity. Marks persist on entries
    /// that are merely filtered out of view, and are pruned only when the entry
    /// actually disappears from the directory.
    public private(set) var selection: Set<VFSPath>

    /// The tree projection, when this pane is in tree mode (PLAN.md §M15 Slice 4) — otherwise `nil`,
    /// and the pane is an ordinary flat list. When set it is the **row source**: `cursor` indexes into
    /// its flattened rows and every selection operation reads its entries from it, so the tree and the
    /// list share one index space rather than being a parallel surface (§6 risk). Marks stay the same
    /// `Set<VFSPath>` regardless of mode, which is exactly why marks span levels for free.
    ///
    /// Its scalar settings (`sort`/`showHidden`/`filter`) and its root listing are kept in lock-step
    /// with `model`, so `model` remains the pane's settings-of-record and the source the tree is
    /// re-seeded from — only the *shape* differs. Navigating (a new `rootPath`) replaces it with a
    /// fresh, all-collapsed tree; a same-directory refresh updates it in place.
    public private(set) var tree: TreeProjection?

    public init(model: DirectoryModel) {
        self.model = model
        cursor = 0
        selection = []
    }

    /// Convenience: an empty panel rooted at `path` until its first listing arrives.
    public init(path: VFSPath, sort: FileSort = .default, showHidden: Bool = false) {
        self.init(model: DirectoryModel(
            listing: DirectoryListing(path: path, entries: []),
            sort: sort,
            showHidden: showHidden
        ))
    }

    // MARK: - Derived state

    public var path: VFSPath { model.listing.path }
    public var count: Int { tree?.count ?? model.count }
    public var isEmpty: Bool { tree?.isEmpty ?? model.isEmpty }

    /// Whether the pane is currently in tree mode.
    public var isTree: Bool { tree != nil }

    /// The entries the pane is showing, in row order — the flat model's visible entries, or the
    /// tree's flattened rows when a `TreeProjection` is installed. Every cursor/selection read goes
    /// through here so the two shapes share one index space (PLAN.md §M15 Slice 4).
    public var displayedEntries: [FileEntry] {
        if let tree { return tree.rows.map(\.entry) }
        return model.visibleEntries
    }

    /// The entry at a display row, or `nil` when the index is out of range.
    public func displayedEntry(at index: Int) -> FileEntry? {
        if let tree { return tree.entry(at: index) }
        return index >= 0 && index < model.count ? model[index] : nil
    }

    /// The display row an entry occupies, by identity, or `nil` when it isn't currently shown.
    ///
    /// The inverse of ``displayedEntry(at:)`` and the other half of the one index space: a caller
    /// holding a `VFSPath` — a cursor to restore after a refresh, a range anchor to sweep from —
    /// must land on the row the pane is *drawing*, which in tree mode is not the flat model's index.
    /// Reaching past this into `model.index(ofID:)` is how a row index and a model index end up
    /// meaning different things (PLAN.md §6: anything that forks is a signal the projection is
    /// wrong, not that the tree needs its own copy).
    public func displayedIndex(ofID id: VFSPath) -> Int? {
        if let tree { return tree.index(ofID: id) }
        return model.index(ofID: id)
    }

    /// The entry under the cursor, or `nil` when the pane shows no rows.
    public var currentEntry: FileEntry? {
        displayedEntry(at: cursor)
    }

    /// Marked entries in current display order (excludes marks on filtered-out rows).
    public var selectedEntries: [FileEntry] {
        displayedEntries.filter { selection.contains($0.id) }
    }

    public var selectionCount: Int { selection.count }

    public func isMarked(_ entry: FileEntry) -> Bool {
        selection.contains(entry.id)
    }

    /// The path to navigate into when opening an entry — a directory, or a symlink
    /// resolving to one. Files return `nil` (the UI launches those instead).
    public func openTarget(for entry: FileEntry) -> VFSPath? {
        entry.isDirectoryLike ? entry.path : nil
    }

    /// The parent directory, or `nil` at the backend root.
    public var parentPath: VFSPath? { model.listing.path.parent }

    // MARK: - Listing

    /// Install a directory snapshot. Same-directory calls are treated as a live
    /// refresh (cursor and selection preserved by identity); a different path is a
    /// navigation (cursor resets to the top, selection clears).
    ///
    /// This re-sorts on the calling actor. Where that sort would jank the main thread (a huge
    /// directory), the app builds the sorted `DirectoryModel` off the main thread and installs it
    /// with `setModel` instead; both funnel through the same reconciliation.
    public mutating func setListing(_ listing: DirectoryListing) {
        let isRefresh = listing.path == model.listing.path
        let anchorID = isRefresh ? currentEntry?.id : nil
        model.updateListing(listing)
        updateTreeAfterModelChange(isRefresh: isRefresh)
        reconcile(isRefresh: isRefresh, anchorID: anchorID)
    }

    /// Install a **pre-sorted** snapshot — the off-main twin of `setListing` (PLAN.md §M7 perf
    /// pass). The caller (via `DirectoryLoader`) has already run the expensive sort on a background
    /// thread, so this does none of it: it just swaps the model in and does the same cheap cursor
    /// and selection reconciliation `setListing` does. Refresh vs navigation is decided identically,
    /// by whether `newModel` describes the same directory. The caller is responsible for setting the
    /// intended `filter`/`directorySizes` on `newModel` before handing it over.
    public mutating func setModel(_ newModel: DirectoryModel) {
        let isRefresh = newModel.listing.path == model.listing.path
        let anchorID = isRefresh ? currentEntry?.id : nil
        model = newModel
        updateTreeAfterModelChange(isRefresh: isRefresh)
        reconcile(isRefresh: isRefresh, anchorID: anchorID)
    }

    /// Shared tail of `setListing`/`setModel`: on a refresh keep the cursor on the same entry by
    /// identity and prune marks to entries that survived; on a navigation reset both. In tree mode the
    /// surviving set is the tree's *whole* entry set, not the root's — otherwise a root refresh would
    /// drop every mark made in an expanded child.
    private mutating func reconcile(isRefresh: Bool, anchorID: VFSPath?) {
        if isRefresh {
            selection.formIntersection(presentEntryIDs)
            restoreCursor(to: anchorID)
        } else {
            selection.removeAll()
            cursor = 0
        }
    }

    /// The identities that still exist after a refresh, for pruning marks: every entry the tree holds
    /// in tree mode (so a mark in one expanded folder survives another's refresh), or the current
    /// directory's entries in list mode.
    private var presentEntryIDs: Set<VFSPath> {
        tree?.allEntryIDs ?? Set(model.listing.entries.map(\.id))
    }

    /// Keep the tree's root listing and scalar settings in step with `model` after it changed. A
    /// same-directory refresh updates the tree in place (expansion and child listings preserved); a
    /// navigation to a new `rootPath` replaces it with a fresh, all-collapsed tree, since the old
    /// expansion belonged to the old root. A no-op in list mode (`tree == nil`).
    private mutating func updateTreeAfterModelChange(isRefresh: Bool) {
        guard tree != nil else { return }
        if isRefresh, var updated = tree {
            updated.sort = model.sort
            updated.showHidden = model.showHidden
            updated.filter = model.filter
            updated.setListing(model.listing.path, entries: model.listing.entries)
            tree = updated
        } else {
            tree = freshTree()
        }
    }

    /// A tree rooted at the current directory, seeded with the current root listing and the model's
    /// sort/hidden/filter, with nothing expanded.
    private func freshTree() -> TreeProjection {
        var fresh = TreeProjection(
            rootPath: model.listing.path,
            sort: model.sort,
            showHidden: model.showHidden,
            filter: model.filter
        )
        fresh.setListing(model.listing.path, entries: model.listing.entries)
        return fresh
    }

    // MARK: - Tree mode

    /// Switch this pane into tree mode, seeding the tree from the current directory and keeping the
    /// cursor on the same entry by identity. A no-op if already in tree mode.
    public mutating func enterTreeMode() {
        guard tree == nil else { return }
        mutatingPreservingCursor { $0.tree = $0.freshTree() }
    }

    /// Switch back to a flat list, keeping the cursor on the same entry by identity where it still
    /// exists at the root (a cursor parked deep in the tree clamps into range). A no-op in list mode.
    public mutating func exitTreeMode() {
        guard tree != nil else { return }
        mutatingPreservingCursor { $0.tree = nil }
    }

    /// Open a folder's children in the tree, keeping the cursor anchored by identity (expanding rows
    /// below the cursor never moves it). A no-op in list mode.
    public mutating func expand(_ path: VFSPath) {
        guard tree != nil else { return }
        mutatingPreservingCursor { $0.tree?.expand(path) }
    }

    /// Close a folder in the tree, keeping any descendant expansion for when it re-opens and the
    /// cursor anchored by identity. A no-op in list mode.
    public mutating func collapse(_ path: VFSPath) {
        guard tree != nil else { return }
        mutatingPreservingCursor { $0.tree?.collapse(path) }
    }

    /// Install a child directory's entries in the tree — its lazy load on expand, or an FSEvents
    /// refresh of an already-open folder — keeping the cursor anchored by identity and pruning marks
    /// to entries that survived across the whole tree. A no-op in list mode.
    public mutating func setTreeChildListing(_ path: VFSPath, entries: [FileEntry]) {
        guard tree != nil else { return }
        mutatingPreservingCursor {
            $0.tree?.setListing(path, entries: entries)
            $0.selection.formIntersection($0.presentEntryIDs)
        }
    }

    // MARK: - View settings (cursor-preserving)

    public mutating func setSort(_ sort: FileSort) {
        mutatingPreservingCursor {
            $0.model.sort = sort
            $0.tree?.sort = sort
        }
    }

    public mutating func setShowHidden(_ showHidden: Bool) {
        mutatingPreservingCursor {
            $0.model.showHidden = showHidden
            $0.tree?.showHidden = showHidden
        }
    }

    public mutating func setFilter(_ filter: String) {
        mutatingPreservingCursor {
            $0.model.filter = filter
            $0.tree?.filter = filter
        }
    }

    /// Record a recursively-computed size for the directory at `id` (Space-on-dir),
    /// keeping the cursor anchored on its entry by identity since size-sorting may
    /// reorder rows once the total lands.
    public mutating func setDirectorySize(_ id: VFSPath, bytes: Int64) {
        mutatingPreservingCursor { $0.model.setDirectorySize(id, bytes: bytes) }
    }

    /// Record many computed directory sizes at once — seeding size-visualization mode from the
    /// `DirectorySizeCache` — with one re-sort rather than one per entry, and the cursor kept
    /// anchored on its entry by identity since size-sorting reorders rows as the totals land.
    public mutating func setDirectorySizes(_ sizes: [VFSPath: Int64]) {
        mutatingPreservingCursor { $0.model.setDirectorySizes(sizes) }
    }

    /// Forget every computed total — the `.gitignore`-aware mode being switched, or its rules
    /// changing (see `DirectoryModel.clearDirectorySizes`). Cursor anchored by identity as above,
    /// since dropping the totals can re-sort a size-sorted listing just as landing them can.
    public mutating func clearDirectorySizes() {
        mutatingPreservingCursor { $0.model.clearDirectorySizes() }
    }

    // MARK: - Cursor

    public mutating func moveCursor(to index: Int) {
        guard !isEmpty else { cursor = 0; return }
        cursor = min(max(index, 0), count - 1)
    }

    public mutating func moveCursor(by delta: Int) {
        moveCursor(to: cursor + delta)
    }

    // MARK: - Selection

    public mutating func toggleMark(at index: Int) {
        guard let entry = entry(at: index) else { return }
        if selection.contains(entry.id) {
            selection.remove(entry.id)
        } else {
            selection.insert(entry.id)
        }
    }

    public mutating func toggleMarkAtCursor() {
        toggleMark(at: cursor)
    }

    /// Toggle the current mark, then advance the cursor — the classic Total
    /// Commander Space/Insert gesture for marking a run of files.
    public mutating func toggleMarkAtCursorAndAdvance() {
        toggleMarkAtCursor()
        moveCursor(by: 1)
    }

    public mutating func selectAll() {
        selection = Set(displayedEntries.map(\.id))
    }

    public mutating func clearSelection() {
        selection.removeAll()
    }

    /// Replace the whole mark set — used to restore marks for undo/redo of a selection change.
    /// Paths that have since vanished from the listing are dropped (mirroring how a live refresh
    /// prunes marks); marks on entries merely filtered out of view survive, since those entries
    /// still exist in the directory.
    public mutating func setSelection(_ ids: Set<VFSPath>) {
        selection = ids.intersection(presentEntryIDs)
    }

    public mutating func invertSelection() {
        for entry in displayedEntries {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
        }
    }

    /// Add every visible entry whose name matches `pattern` to the selection (`+`).
    public mutating func selectMatching(_ pattern: String) {
        for entry in displayedEntries where Glob.matches(pattern, entry.name) {
            selection.insert(entry.id)
        }
    }

    /// Remove every visible entry whose name matches `pattern` from the selection (`-`).
    public mutating func deselectMatching(_ pattern: String) {
        for entry in displayedEntries where Glob.matches(pattern, entry.name) {
            selection.remove(entry.id)
        }
    }

    // MARK: - Mouse (Finder-style) selection

    /// Finder's Cmd-click: flip the mark on the entry at `index` and move the cursor
    /// onto it (a no-op for an out-of-range index).
    public mutating func toggleMarkMovingCursor(to index: Int) {
        guard entry(at: index) != nil else { return }
        toggleMark(at: index)
        moveCursor(to: index)
    }

    /// Finder's Shift-click: mark the inclusive run of visible entries between `anchor`
    /// and `index`, unioned onto `base` — the marks that predate this range sweep, so a
    /// Shift-click keeps earlier Cmd-clicked marks and each re-sweep from the same anchor
    /// replaces only the previous run. Both indices are clamped to the visible entries,
    /// and the cursor lands on `index`.
    public mutating func selectRange(from anchor: Int, through index: Int, base: Set<VFSPath>) {
        guard !isEmpty else { return }
        let lastRow = count - 1
        let anchorRow = min(max(anchor, 0), lastRow)
        let targetRow = min(max(index, 0), lastRow)
        var marks = base
        for row in min(anchorRow, targetRow)...max(anchorRow, targetRow) {
            if let entry = displayedEntry(at: row) { marks.insert(entry.id) }
        }
        selection = marks
        moveCursor(to: index)
    }

    // MARK: - Helpers

    private func entry(at index: Int) -> FileEntry? {
        displayedEntry(at: index)
    }

    private mutating func mutatingPreservingCursor(_ body: (inout Panel) -> Void) {
        let anchorID = currentEntry?.id
        body(&self)
        restoreCursor(to: anchorID)
    }

    private mutating func restoreCursor(to id: VFSPath?) {
        if let id, let index = displayedIndex(ofID: id) {
            cursor = index
        } else {
            cursor = isEmpty ? 0 : min(cursor, count - 1)
        }
    }
}
