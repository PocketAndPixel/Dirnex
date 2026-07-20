import AppKit
import DirnexCore

/// Drag-and-drop for the sidebar's Favorites section (PLAN.md §M8): reordering pins by dragging
/// them, and pinning a folder by dragging it in from a pane. Both land in `Hotlist`, whose
/// `move(from:to:)` and `insert(_:at:)` own the ordering rules and are tested headless; what lives
/// here is the mapping between `NSTableView`'s row indices and the pin list's own.
///
/// Only Favorites participates. Volumes is a mount-table snapshot re-sorted on every mount event,
/// and Searches/Servers/Tags have their own identity-keyed stores — none of them has anywhere to
/// put a user order, so their rows are neither draggable nor droppable.
extension SidebarViewController {
    /// Identifies our own row drag on the pasteboard. Checking for this type is more reliable than
    /// comparing dragging-source identity, which a synthetic drag doesn't preserve (the lesson the
    /// hotlist organizer's reorder already encodes).
    static let favoriteRowType = NSPasteboard.PasteboardType("com.dirnex.sidebar.favorite-row")

    /// Called from `loadView`. Accepts our own rows (reorder) and file URLs (a folder dragged in
    /// from a pane, or from Finder).
    func registerFavoriteDragTypes() {
        tableView.registerForDraggedTypes([Self.favoriteRowType, .fileURL])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        // Nothing is offered to other applications: dragging a favorite out of the sidebar is a
        // reorder gesture, and letting it also read as "copy this folder to Finder" would make an
        // aimed-badly reorder do real filesystem work.
        tableView.setDraggingSourceOperationMask([], forLocal: false)
    }

    /// The row indices a drop may target: every insertion point in the Favorites section, from
    /// above its first pin through below its last.
    ///
    /// Empty-safe by construction — with nothing pinned this collapses to the single insertion
    /// point just below the header, which is exactly the drop target an empty section needs (and
    /// why `rebuild()` renders that header even when the section holds nothing). A **folded**
    /// section collapses to that same single point, since it contributes no rows; `acceptDrop`
    /// unfolds it so the pin lands somewhere the user can see.
    var favoriteDropRange: ClosedRange<Int> {
        guard let header = headerRow(of: .favorites) else { return 0...0 }
        let start = header + 1
        let pinned = rows[start...].prefix { $0.favorite != nil }.count
        return start...(start + pinned)
    }

    // MARK: - Dragging out (reorder)

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        // Only a pinned row is draggable; every other section returns nil and simply doesn't lift.
        guard rows.indices.contains(row), rows[row].favorite != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.favoriteRowType)
        return item
    }

    // MARK: - Dropping in

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: any NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation _: NSTableView.DropOperation
    ) -> NSDragOperation {
        let target = clampedToFavorites(row)
        // Always retarget to an insertion point inside Favorites — including a drop proposed *on* a
        // row, or one aimed at another section entirely. The insertion line then shows exactly where
        // the pin will land, so a drop anywhere in the sidebar does the one thing that makes sense
        // rather than silently doing nothing.
        if info.draggingPasteboard.availableType(from: [Self.favoriteRowType]) != nil {
            tableView.setDropRow(target, dropOperation: .above)
            return .move
        }
        guard !droppedDirectories(from: info).isEmpty else { return [] }
        tableView.setDropRow(target, dropOperation: .above)
        return .copy
    }

    func tableView(
        _: NSTableView,
        acceptDrop info: any NSDraggingInfo,
        row: Int,
        dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        let base = favoriteDropRange.lowerBound
        let index = clampedToFavorites(row) - base
        var hotlist = HotlistStore.load()

        if let raw = info.draggingPasteboard.string(forType: Self.favoriteRowType),
           let sourceRow = Int(raw) {
            // `NSTableView` reports the drop as an insertion index in *pre-removal* coordinates,
            // while `Hotlist.move` takes a destination in the resulting list — so a move further
            // down shifts by one to land where the gap was. Same adjustment the organizer sheet
            // makes; it is the one off-by-one this whole feature hinges on.
            let source = sourceRow - base
            hotlist.move(from: source, to: index > source ? index - 1 : index)
            HotlistStore.save(hotlist)
            return true
        }

        let directories = droppedDirectories(from: info)
        guard !directories.isEmpty else { return false }
        var changed = false
        for (offset, url) in directories.enumerated() {
            let entry = HotlistEntry(path: .local(url.path))
            changed = hotlist.insert(entry, at: index + offset) || changed
        }
        guard changed else { return false }
        HotlistStore.save(hotlist)
        // A drop onto a folded Favorites section unfolds it. The pin is otherwise filed into rows
        // that are not on screen, which is indistinguishable from the drag having been refused.
        expandSection(.favorites)
        return true
    }

    // MARK: - Helpers

    /// Pull `row` onto the nearest insertion point inside Favorites.
    private func clampedToFavorites(_ row: Int) -> Int {
        let range = favoriteDropRange
        return min(max(row, range.lowerBound), range.upperBound)
    }

    /// The directories among the dragged file URLs. Files are dropped silently rather than pinned:
    /// a hotlist entry navigates a pane to a folder, so a pinned file would be a row that cannot do
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
