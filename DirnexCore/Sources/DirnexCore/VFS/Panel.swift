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
    public var count: Int { model.count }
    public var isEmpty: Bool { model.isEmpty }

    /// The entry under the cursor, or `nil` when the directory shows no rows.
    public var currentEntry: FileEntry? {
        !model.isEmpty && cursor < model.count ? model[cursor] : nil
    }

    /// Marked entries in current display order (excludes marks on filtered-out rows).
    public var selectedEntries: [FileEntry] {
        model.visibleEntries.filter { selection.contains($0.id) }
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
        reconcile(isRefresh: isRefresh, anchorID: anchorID)
    }

    /// Shared tail of `setListing`/`setModel`: on a refresh keep the cursor on the same entry by
    /// identity and prune marks to entries that survived; on a navigation reset both.
    private mutating func reconcile(isRefresh: Bool, anchorID: VFSPath?) {
        if isRefresh {
            selection.formIntersection(Set(model.listing.entries.map(\.id)))
            restoreCursor(to: anchorID)
        } else {
            selection.removeAll()
            cursor = 0
        }
    }

    // MARK: - View settings (cursor-preserving)

    public mutating func setSort(_ sort: FileSort) {
        mutatingPreservingCursor { $0.model.sort = sort }
    }

    public mutating func setShowHidden(_ showHidden: Bool) {
        mutatingPreservingCursor { $0.model.showHidden = showHidden }
    }

    public mutating func setFilter(_ filter: String) {
        mutatingPreservingCursor { $0.model.filter = filter }
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

    // MARK: - Cursor

    public mutating func moveCursor(to index: Int) {
        guard !model.isEmpty else { cursor = 0; return }
        cursor = min(max(index, 0), model.count - 1)
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
        selection = Set(model.visibleEntries.map(\.id))
    }

    public mutating func clearSelection() {
        selection.removeAll()
    }

    /// Replace the whole mark set — used to restore marks for undo/redo of a selection change.
    /// Paths that have since vanished from the listing are dropped (mirroring how a live refresh
    /// prunes marks); marks on entries merely filtered out of view survive, since those entries
    /// still exist in the directory.
    public mutating func setSelection(_ ids: Set<VFSPath>) {
        selection = ids.intersection(Set(model.listing.entries.map(\.id)))
    }

    public mutating func invertSelection() {
        for entry in model.visibleEntries {
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
        }
    }

    /// Add every visible entry whose name matches `pattern` to the selection (`+`).
    public mutating func selectMatching(_ pattern: String) {
        for entry in model.visibleEntries where Glob.matches(pattern, entry.name) {
            selection.insert(entry.id)
        }
    }

    /// Remove every visible entry whose name matches `pattern` from the selection (`-`).
    public mutating func deselectMatching(_ pattern: String) {
        for entry in model.visibleEntries where Glob.matches(pattern, entry.name) {
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
        guard !model.isEmpty else { return }
        let lastRow = model.count - 1
        let anchorRow = min(max(anchor, 0), lastRow)
        let targetRow = min(max(index, 0), lastRow)
        var marks = base
        for row in min(anchorRow, targetRow)...max(anchorRow, targetRow) {
            marks.insert(model[row].id)
        }
        selection = marks
        moveCursor(to: index)
    }

    // MARK: - Helpers

    private func entry(at index: Int) -> FileEntry? {
        index >= 0 && index < model.count ? model[index] : nil
    }

    private mutating func mutatingPreservingCursor(_ body: (inout Panel) -> Void) {
        let anchorID = currentEntry?.id
        body(&self)
        restoreCursor(to: anchorID)
    }

    private mutating func restoreCursor(to id: VFSPath?) {
        if let id, let index = model.index(ofID: id) {
            cursor = index
        } else {
            cursor = model.isEmpty ? 0 : min(cursor, model.count - 1)
        }
    }
}
