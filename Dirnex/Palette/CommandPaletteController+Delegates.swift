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
    /// the highlight, ⏎ runs the highlighted command, ⎋ closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            runSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        default:
            return false
        }
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
