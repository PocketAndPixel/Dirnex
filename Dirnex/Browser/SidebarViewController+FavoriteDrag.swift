import AppKit
import DirnexCore

/// Drag-and-drop for the sidebar's **user-ordered** sections (PLAN.md §M8): reordering their rows by
/// dragging them, and — Favorites alone — pinning a folder by dragging it in from a pane. The
/// ordering rules live in the core value types (`Favorites`, `SavedSearches`, `ServerConnections`),
/// each with a tested `move(from:to:)`; what lives here is the mapping between `NSTableView`'s row
/// indices and each list's own.
///
/// Three sections reorder — Favorites, Searches and Servers — because each is a user-authored
/// ordered list with somewhere to store the order. The rest do not: Volumes is a mount-table
/// snapshot re-sorted on every mount event, Cloud mounts are discovered under
/// `~/Library/CloudStorage`, and Tags are Finder's fixed set — none has a place to put a user order,
/// so their rows are neither draggable nor droppable.
///
/// **A reorder stays within its own section.** A drag started on a server can only land among
/// servers, never among favorites: they are different kinds of thing, not repositionable peers. The
/// pasteboard payload therefore carries the source *section* as well as the row, and every drop is
/// clamped back into that section's own insertion range. Only Favorites additionally accepts a
/// *folder* dragged in (from a pane or Finder), which pins it.
extension SidebarViewController {
    /// Identifies our own row drag on the pasteboard, carrying `"<section-raw-value>:<row>"`.
    /// Checking for this type is more reliable than comparing dragging-source identity, which a
    /// synthetic drag doesn't preserve (the lesson the favorites organizer's reorder already
    /// encodes).
    static let reorderRowType = NSPasteboard.PasteboardType("com.dirnex.sidebar.reorder-row")

    /// Called from `loadView`. Accepts our own rows (reorder) and file URLs (a folder dragged into
    /// Favorites from a pane, or from Finder).
    func registerSidebarDragTypes() {
        tableView.registerForDraggedTypes([Self.reorderRowType, .fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        // Nothing is offered to other applications: dragging a row out of the sidebar is a reorder
        // gesture, and letting a favorite also read as "copy this folder to Finder" would make an
        // aimed-badly reorder do real filesystem work.
        tableView.setDraggingSourceOperationMask([], forLocal: false)
    }

    /// The reorderable section a row is an *item* of, or `nil` for a header, a system row (Recents,
    /// Trash), or an item of a non-reorderable section (a volume, an iCloud/cloud-mount row, a tag).
    func reorderableSection(ofRow row: Int) -> SidebarSection? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .favorite: return .favorites
        case .savedSearch: return .searches
        case .server: return .servers
        default: return nil
        }
    }

    /// The row indices a drop may target within `section`: every insertion point among its items,
    /// from above its first through below its last, or `nil` when the section isn't on screen.
    ///
    /// Empty-safe by construction — a Favorites section with nothing pinned still renders its header
    /// (`append`'s `showsEmptyHeader`), so this collapses to the single insertion point just below
    /// that header. A **folded** section collapses to the same single point, since it contributes no
    /// item rows; `acceptDrop` unfolds it so the pin lands somewhere the user can see. A Searches or
    /// Servers section that is empty has no header at all, so this returns `nil` — there is nothing
    /// to drag out of it and nowhere to drop into it.
    func dropRange(for section: SidebarSection) -> ClosedRange<Int>? {
        guard let header = headerRow(of: section) else { return nil }
        let start = header + 1
        var end = start
        // A section's items are contiguous right after its header, so the run stops at the first row
        // that isn't one of them (the next header, or the end of the list).
        while end < rows.count, reorderableSection(ofRow: end) == section { end += 1 }
        return start...end
    }

    // MARK: - Dragging out (reorder)

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // Only a row that belongs to a reorderable section lifts; every other row returns nil.
        guard let section = reorderableSection(ofRow: row) else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(section.rawValue):\(row)", forType: Self.reorderRowType)
        return item
    }

    // MARK: - Dropping in

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation _: NSTableView.DropOperation
    ) -> NSDragOperation {
        // A reorder always retargets to an insertion point inside its *own* section — including a
        // drop proposed on a row, or one aimed at another section entirely. The insertion line then
        // shows exactly where the row will land, so a drop anywhere in the sidebar does the one thing
        // that makes sense rather than silently doing nothing.
        if let (section, _) = reorderPayload(from: info), let range = dropRange(for: section) {
            tableView.setDropRow(clamp(row, to: range), dropOperation: .above)
            return .move
        }
        // A folder dragged in from a pane or Finder pins into Favorites.
        guard !droppedDirectories(from: info).isEmpty, let range = dropRange(for: .favorites) else {
            return []
        }
        tableView.setDropRow(clamp(row, to: range), dropOperation: .above)
        return .copy
    }

    func tableView(
        _: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        if let (section, sourceRow) = reorderPayload(from: info) {
            return reorder(section: section, fromRow: sourceRow, toProposedRow: row)
        }
        return pinDroppedDirectories(from: info, atProposedRow: row)
    }

    // MARK: - Reorder

    /// Move a row within its section, dispatching to that section's own store. Each store's
    /// `move(from:to:)` is a tested core method, so this is purely the row-index mapping.
    private func reorder(section: SidebarSection, fromRow: Int, toProposedRow row: Int) -> Bool {
        guard let range = dropRange(for: section) else { return false }
        let base = range.lowerBound
        let source = fromRow - base
        // `NSTableView` reports the drop as an insertion index in *pre-removal* coordinates, while
        // `move(from:to:)` takes a destination in the resulting list — so a move further down shifts
        // by one to land where the gap was. The one off-by-one this whole feature hinges on; the
        // favorites organizer sheet makes the identical adjustment.
        let destination = clamp(row, to: range) - base
        let adjusted = destination > source ? destination - 1 : destination
        switch section {
        case .favorites:
            var store = FavoritesStore.load()
            store.move(from: source, to: adjusted)
            FavoritesStore.save(store)
        case .searches:
            var store = SavedSearchStore.load()
            store.move(from: source, to: adjusted)
            SavedSearchStore.save(store)
        case .servers:
            var store = ServerConnectionStore.load()
            store.move(from: source, to: adjusted)
            ServerConnectionStore.save(store)
        default:
            return false
        }
        return true
    }

    // MARK: - Pin (Favorites only)

    private func pinDroppedDirectories(from info: any NSDraggingInfo, atProposedRow row: Int) -> Bool {
        let directories = droppedDirectories(from: info)
        guard !directories.isEmpty, let range = dropRange(for: .favorites) else { return false }
        let index = clamp(row, to: range) - range.lowerBound
        var favorites = FavoritesStore.load()
        var changed = false
        for (offset, url) in directories.enumerated() {
            let entry = FavoriteEntry(path: .local(url.path))
            changed = favorites.insert(entry, at: index + offset) || changed
        }
        guard changed else { return false }
        FavoritesStore.save(favorites)
        // A drop onto a folded Favorites section unfolds it. The pin is otherwise filed into rows
        // that are not on screen, which is indistinguishable from the drag having been refused.
        expandSection(.favorites)
        return true
    }

    // MARK: - Helpers

    /// Parse our reorder pasteboard payload into its source section and row, or `nil` if the drag
    /// isn't one of ours (a file-URL drag, or another app's).
    private func reorderPayload(from info: any NSDraggingInfo) -> (SidebarSection, Int)? {
        guard let raw = info.draggingPasteboard.string(forType: Self.reorderRowType) else {
            return nil
        }
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let section = SidebarSection(rawValue: String(parts[0])),
              let row = Int(parts[1]) else { return nil }
        return (section, row)
    }

    /// Pull `row` onto the nearest insertion point inside `range`.
    private func clamp(_ row: Int, to range: ClosedRange<Int>) -> Int {
        min(max(row, range.lowerBound), range.upperBound)
    }

    /// The directories among the dragged file URLs. Files are dropped silently rather than pinned:
    /// a favorites entry navigates a pane to a folder, so a pinned file would be a row that cannot do
    /// the one thing a row does.
    private func droppedDirectories(from info: any NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        )
        guard let urls = objects as? [URL] else { return [] }
        return urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
