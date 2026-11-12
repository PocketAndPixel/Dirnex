import AppKit
import DirnexCore

/// The name column's icons (2026-11-11): a folder's own icon, and with View ▸ Show Icon Previews a
/// picture of an image's, a movie's or a PDF's content, the way Finder's list view draws them.
/// `RowIcon` decides which a row gets; `RowIconLoader` loads the images off the main thread, and this
/// pane draws a placeholder until then and swaps the image in on the rows that are on screen.
extension PanelViewController {
    /// The icon for `entry`'s row now: the loaded image if it is in, the placeholder otherwise.
    func rowIconImage(for entry: FileEntry) -> NSImage {
        let icon = RowIcon.of(
            entry,
            mounts: MountTable.current(),
            showsPreviews: AppPreferences.shared.showIconPreviews
        )
        let placeholder = FileIconProvider.placeholder(for: icon)
        let kind: RowIconLoader.Kind
        switch icon {
        case .item: kind = .item
        case .thumbnail: kind = .thumbnail
        case .folder, .type: return placeholder
        }
        return RowIconLoader.shared.image(
            for: entry,
            kind: kind,
            pointSize: AppPreferences.shared.rowDensity.iconSize,
            scale: tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            appearance: tableView.effectiveAppearance
        ) ?? placeholder
    }

    // MARK: - Command (dispatched to the focused pane via the responder chain)

    /// View ▸ Show Icon Previews. App-wide, like Show Tags: every pane follows the preference's own
    /// notification rather than being reached from here.
    @objc func toggleShowIconPreviews(_ sender: Any?) {
        AppPreferences.shared.toggleShowIconPreviews()
    }

    // MARK: - Keeping up to date

    func observeRowIcons() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(rowIconsNeedRefresh),
            name: RowIconLoader.didLoadNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(rowIconsNeedRefresh),
            name: AppPreferences.showIconPreviewsDidChange,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(rowIconsNeedRefresh),
            name: FileIconProvider.typeIconsDidChange,
            object: nil
        )
    }

    @objc private func rowIconsNeedRefresh(_ notification: Notification) {
        refreshVisibleRowIcons()
    }

    /// Ask again for the icon of every row on screen and put it in the row's cell. Only the image
    /// changes, so nothing is reloaded: the cursor, the marks and an open rename field stay as they
    /// are. A row off screen is asked when it is drawn.
    func refreshVisibleRowIcons() {
        let column = tableView.column(
            withIdentifier: NSUserInterfaceItemIdentifier(Column.name.rawValue)
        )
        guard column >= 0 else { return }
        let rows = tableView.rows(in: tableView.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard !isParentRow(row),
                  let index = entryIndex(forRow: row),
                  let entry = panel.displayedEntry(at: index),
                  let cell = tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? FileCellView
            else { continue }
            cell.imageView?.image = iCloudLibraryIcon(for: entry) ?? rowIconImage(for: entry)
        }
    }
}
