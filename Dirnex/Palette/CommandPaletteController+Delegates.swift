import AppKit
import DirnexCore

// MARK: - Result list data source / delegate

extension CommandPaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        matches.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(
            withIdentifier: CommandPaletteRowView.reuseIdentifier,
            owner: self
        ) as? CommandPaletteRowView ?? {
            let view = CommandPaletteRowView()
            view.identifier = CommandPaletteRowView.reuseIdentifier
            return view
        }()
        guard matches.indices.contains(row) else { return cell }
        let match = matches[row]
        cell.configure(
            with: match,
            shortcut: shortcut(for: match.command),
            selected: row == selectedIndex
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIndex = tableView.selectedRow
        reconfigureVisibleRows()
    }

    /// Re-render every on-screen row so the highlighted row's text flips to white and the
    /// previously highlighted row flips back — the selection fill and the text color are
    /// applied together, and there are only ever a handful of visible rows.
    private func reconfigureVisibleRows() {
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        for row in range.location..<NSMaxRange(range) {
            guard matches.indices.contains(row),
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                  as? CommandPaletteRowView else { continue }
            let match = matches[row]
            cell.configure(
                with: match,
                shortcut: shortcut(for: match.command),
                selected: row == selectedIndex
            )
        }
    }
}

// MARK: - Search field

extension CommandPaletteController: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        reload(query: searchField.stringValue)
    }

    /// The search field is first responder, so the arrow/return/escape keys arrive here as
    /// editing commands rather than reaching the list. Route them to the palette: ↑/↓ move
    /// the highlight, ⏎ runs the highlighted command, ⌘⏎ opens a place in a new tab, ⎋ closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let key = PaletteKey.action(for: selector, event: NSApp.currentEvent) else { return false }
        switch key {
        case .moveUp: moveSelection(by: -1)
        case .moveDown: moveSelection(by: 1)
        case let .run(inNewTab): runSelected(inNewTab: inNewTab)
        case .close: dismiss()
        }
        return true
    }
}

// MARK: - Panel lifecycle

extension CommandPaletteController: NSWindowDelegate {
    /// Clicking back into the browser window (or anywhere outside the palette) resigns the
    /// panel's key status — treat that as a dismissal, the standard palette behavior.
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}
