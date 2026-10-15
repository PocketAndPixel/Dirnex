import AppKit

@testable import Dirnex

/// A pane's table in a window of its own, with a Name column too narrow for ``longName``. Shared by
/// the suites for the floated panel (`ExpansionPanel`) and the two gestures that put it up.
@MainActor
final class ExpansionTableFixture: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    static let longName = "WestWorld.S01E09.The.Well-Tempered.Clavier.mkv"

    let table = FileTableView()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 220, height: 200),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    private let names: [String]

    /// Kept for the life of the test host: tearing a test window down can crash a later test
    /// (docs/NOTES.md ▸ Testing, windows in a test).
    private static var retained: [ExpansionTableFixture] = []

    init(names: [String]) {
        self.names = names
        super.init()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier(PanelViewController.Column.name.rawValue)
        )
        column.width = 200
        table.addTableColumn(column)
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 200))
        scrollView.documentView = table
        window.contentView = NSView(frame: scrollView.frame)
        window.contentView?.addSubview(scrollView)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        settle()
        Self.retained.append(self)
    }

    /// Reload the rows and lay them out, as a listing refresh does. Every row gets a new cell view.
    func settle() {
        table.reloadData()
        for _ in 0..<2 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// Row `row`'s name label.
    func label(atRow row: Int) -> NSTextField? {
        (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?.textField
    }

    /// The point on screen at the middle of `view`.
    func screenPoint(atMiddleOf view: NSView) -> NSPoint {
        window.convertPoint(
            toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        )
    }

    func numberOfRows(in tableView: NSTableView) -> Int { names.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = FileCellView(showsImage: true, identifier: NSUserInterfaceItemIdentifier("name"))
        cell.textField?.stringValue = names[row]
        return cell
    }
}
