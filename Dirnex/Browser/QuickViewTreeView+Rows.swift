import AppKit
import DirnexCore

/// A value, as the tree's outline view holds it. A class, since the outline view keeps a row's
/// expanded state against the object (`QuickViewTreeView.item(for:)`).
final class QuickViewTreeItem: NSObject {
    let value: Int

    init(value: Int) {
        self.value = value
    }
}

/// The tree itself, which puts the selected value on the pasteboard — the twin of the table's
/// `QuickViewDataTableView`.
@MainActor
final class QuickViewTreeOutlineView: NSOutlineView, NSMenuItemValidation {
    var copiedText: (() -> String?)?
    /// Where ⌘C writes. The general pasteboard, except in a test, which must not overwrite the
    /// clipboard of whoever is running it.
    var pasteboard = NSPasteboard.general

    @objc func copy(_ sender: Any?) {
        guard let text = copiedText?(), !text.isEmpty else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return selectedRow >= 0
    }
}

// MARK: - Rows and cells

extension QuickViewTreeView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    // With no filter a value's rows are read straight off the document; with one, they are the ones it
    // leaves (`shownChildren`).

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let document else { return 0 }
        guard let item = item as? QuickViewTreeItem else { return topLevel.count }
        return filter == nil
            ? document.childCount(of: item.value)
            : shownChildren(of: item.value).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let document, let parent = item as? QuickViewTreeItem else {
            return self.item(for: topLevel[index])
        }
        return self.item(for: filter == nil
            ? document.child(index, of: parent.value)
            : shownChildren(of: parent.value)[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let document, let item = item as? QuickViewTreeItem else { return false }
        return filter == nil
            ? document.childCount(of: item.value) > 0
            : !shownChildren(of: item.value).isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let document, let item = item as? QuickViewTreeItem, let tableColumn else { return nil }
        let cell = outlineView.makeView(withIdentifier: QuickViewTableCell.identifier, owner: nil)
            as? QuickViewTableCell ?? QuickViewTableCell()
        let inKeys = tableColumn.identifier == Self.keyColumn
        let label = inKeys ? document.keyLabel(of: item.value) : document.valueLabel(of: item.value)
        cell.show(
            label.text,
            font: zoomedFont,
            color: Self.color(for: label.role),
            alignment: .left,
            marking: markedQuery(for: item.value, inKeys: inKeys),
            within: label.searched
        )
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        showSelectedValue()
    }

    /// A key column somebody dragged keeps its new width, in proportion, through later zooms.
    func outlineViewColumnDidResize(_ notification: Notification) {
        guard !isApplyingZoom,
              let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              column.identifier == Self.keyColumn
        else { return }
        baseKeyWidth = column.width / CGFloat(zoomLevel)
    }

    // MARK: - Labels

    /// The source view's color for a kind of text: a string, a number and a word as they are colored
    /// there, a key, a name or an element's text in the label color, and what the tree says about a value
    /// — an index, a count, an element's attributes — dimmed.
    static func color(for role: TreeLabel.Role) -> NSColor {
        switch role {
        case .name, .text: .labelColor
        case .annotation: .secondaryLabelColor
        case .string: SyntaxTheme.string
        case .number: SyntaxTheme.number
        case .keyword: SyntaxTheme.keyword
        }
    }

    /// The query to mark in a value's key or its text: the one the tree is filtered by, where the
    /// picker reads that column and the value is a match itself. A value shown because it lies inside a
    /// matched container, or on the way down to one, matched nothing.
    private func markedQuery(for value: Int, inKeys: Bool) -> FilterQuery? {
        guard let filterMarking, filter?.isMatch(value) == true else { return nil }
        switch filterMarking.scope {
        case .keysAndValues:
            return filterMarking.query
        case .keys:
            return inKeys ? filterMarking.query : nil
        case .values:
            return inKeys ? nil : filterMarking.query
        }
    }
}
