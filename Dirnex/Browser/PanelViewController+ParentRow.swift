import AppKit
import DirnexCore

/// The synthetic `..` parent row (PLAN.md §M1 "a `..` parent row"). Total Commander
/// shows it at the top of every non-root directory as a one-click way up.
///
/// It lives entirely in the UI: `Panel` never sees it, so selection counts, marks,
/// sizing and glob-select stay clean. The table therefore has one more row than
/// `panel.count` at non-root paths, and every row⇄entry mapping goes through the
/// helpers here. All of this is read-only with respect to `Panel`.
extension PanelViewController {
    /// 1 when a `..` row is shown, else 0 — also the offset between a table row and its entry
    /// index. Shown on any non-root local directory, and inside an archive at every level: the
    /// `..` walks up the inner tree and, at the archive root, exits to the containing folder. A
    /// virtual *search-results* pane never shows one — its synthetic parent isn't browsable.
    var parentRowCount: Int {
        if isArchive { return 1 }
        return panel.path.backend == .local && panel.parentPath != nil ? 1 : 0
    }

    func isParentRow(_ row: Int) -> Bool {
        parentRowCount == 1 && row == 0
    }

    /// The `panel` entry index a table row maps to, or `nil` for the `..` row / out of
    /// range.
    func entryIndex(forRow row: Int) -> Int? {
        let index = row - parentRowCount
        return index >= 0 && index < panel.count ? index : nil
    }

    /// The table row that shows a given entry index.
    func row(forEntryIndex index: Int) -> Int {
        index + parentRowCount
    }

    /// Build the cell for the `..` row: an up-to-the-folder label with no size or date,
    /// never marked.
    func parentRowCell(for column: Column, in tableView: NSTableView) -> FileCellView {
        let identifier = NSUserInterfaceItemIdentifier(column.rawValue)
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? FileCellView
            ?? FileCellView(showsImage: column == .name, identifier: identifier)
        cell.marked = false
        cell.dimmed = false
        cell.accentColor = nil
        switch column {
        case .name:
            cell.imageView?.image = FileIconProvider.parentIcon
            cell.textField?.stringValue = ".."
            cell.textField?.alignment = .natural
        // `..` is a way out, not a file: it has no size, no date, and no Git status — the folder it
        // points at may not even be in this repository.
        case .size, .date, .git:
            cell.textField?.stringValue = ""
        // Unreachable: the bar column is answered by `sizeBarCell` before the parent row is ever
        // considered, because its cell is not a `FileCellView`. Listed for exhaustiveness.
        case .sizeBar:
            cell.textField?.stringValue = ""
        }
        cell.applyStyle()
        return cell
    }
}
