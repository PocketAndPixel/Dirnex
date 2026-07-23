import AppKit
import DirnexCore

// The master list of the scripts organizer sheet: the `NSTableView` data source and delegate.
// Split out of `UserScriptsOrganizerController.swift` so that file stays under SwiftLint's
// `file_length` ceiling (localization pushed it over). Reaches the controller's `scripts` and
// `loadDetail()`, which are `internal` for exactly this reason (docs/NOTES.md file-splitting).

extension UserScriptsOrganizerController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        scripts.scripts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard scripts.scripts.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("UserScriptCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        cell.textField?.stringValue = scripts.scripts[row].name
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        loadDetail()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
