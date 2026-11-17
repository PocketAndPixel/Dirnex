import AppKit
import DirnexCore

/// The name column's icons (2026-11-11): a folder's own icon, and with View ▸ Show Icon Previews a
/// picture of an image's, a movie's or a PDF's content, the way Finder's list view draws them.
/// `RowIcon` decides which a row gets; `RowIconLoader` loads the images off the main thread, and this
/// pane draws a placeholder until then and swaps the image in on the rows that are on screen.
///
/// An arrival (``applyArrivedRowIcons(_:)``) puts in the images that came, and only then asks again for
/// the other rows on screen. In that order because a cache under memory pressure can let an image go
/// before its row is asked: when an arrival only asked, such a row got its placeholder back and another
/// load, whose arrival asked again, and the icons blinked several times a second (2026-11-17,
/// `RowIconLoader`). The asking stays, for a row whose request the loader's full queue dropped, and it
/// takes nothing down: a row already drawing its image is answered with that image.
extension PanelViewController {
    /// What `entry`'s row draws until a loaded image is in, and the key that image is loaded under,
    /// `nil` for a row that only ever draws the placeholder.
    func rowIconRequest(for entry: FileEntry) -> (placeholder: NSImage, key: RowIconLoader.Key?) {
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
        case .folder, .type: return (placeholder, nil)
        }
        let key = RowIconLoader.shared.key(
            for: entry,
            kind: kind,
            pointSize: AppPreferences.shared.rowDensity.iconSize,
            scale: tableView.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            appearance: tableView.effectiveAppearance
        )
        return (placeholder, key)
    }

    /// Put `entry`'s icon in its name cell, asking the loader for it: the loaded image if it is in,
    /// the placeholder and a load otherwise.
    func applyRowIcon(to cell: FileCellView, for entry: FileEntry) {
        if let libraryIcon = iCloudLibraryIcon(for: entry) {
            cell.imageView?.image = libraryIcon
            return
        }
        let request = rowIconRequest(for: entry)
        cell.imageView?.image = request.key.flatMap { RowIconLoader.shared.image(for: $0) }
            ?? request.placeholder
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
            selector: #selector(rowIconsDidLoad),
            name: RowIconLoader.didLoadNotification,
            object: nil
        )
        for name in [
            RowIconLoader.keysDidChangeNotification,
            AppPreferences.showIconPreviewsDidChange,
            FileIconProvider.typeIconsDidChange
        ] {
            center.addObserver(
                self,
                selector: #selector(rowIconsNeedAsking),
                name: name,
                object: nil
            )
        }
    }

    @objc private func rowIconsDidLoad(_ notification: Notification) {
        applyArrivedRowIcons(RowIconLoader.arrivals(in: notification))
    }

    @objc private func rowIconsNeedAsking(_ notification: Notification) {
        refreshVisibleRowIcons()
    }

    /// Put each image that has just arrived in the row on screen it is for, and ask again for every
    /// other row on screen (see the type's comment).
    func applyArrivedRowIcons(_ arrivals: [RowIconLoader.Key: NSImage]) {
        forEachVisibleNameCell { cell, entry in
            if iCloudLibraryIcon(for: entry) == nil,
               let key = rowIconRequest(for: entry).key,
               let image = arrivals[key] {
                cell.imageView?.image = image
            } else {
                applyRowIcon(to: cell, for: entry)
            }
        }
    }

    /// Ask again for the icon of every row on screen and put it in the row's cell. Only the image
    /// changes, so nothing is reloaded: the cursor, the marks and an open rename field stay as they
    /// are. A row off screen is asked when it is drawn.
    func refreshVisibleRowIcons() {
        forEachVisibleNameCell { cell, entry in applyRowIcon(to: cell, for: entry) }
    }

    /// The name cell and entry of every row on screen that has both, `..` left out.
    private func forEachVisibleNameCell(_ body: (FileCellView, FileEntry) -> Void) {
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
            body(cell, entry)
        }
    }
}
