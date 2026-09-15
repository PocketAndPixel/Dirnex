import AppKit
import DirnexCore

/// A value, as the JSON tree's outline view holds it. A class, since the outline view keeps a row's
/// expanded state against the object (`QuickViewJSONTreeView.item(for:)`).
final class QuickViewJSONItem: NSObject {
    let value: Int

    init(value: Int) {
        self.value = value
    }
}

/// The tree itself, which puts the selected value on the pasteboard — the twin of the table's
/// `QuickViewDataTableView`.
@MainActor
final class QuickViewJSONOutlineView: NSOutlineView, NSMenuItemValidation {
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

extension QuickViewJSONTreeView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    // With no filter a container's children are read straight off the document; with one, they are
    // the ones it leaves (`shownChildren`).

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let document else { return 0 }
        guard let item = item as? QuickViewJSONItem else { return topLevel.count }
        return filter == nil
            ? document.childCount(of: item.value)
            : shownChildren(of: item.value).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let document, let parent = item as? QuickViewJSONItem else {
            return self.item(for: topLevel[index])
        }
        return self.item(for: filter == nil
            ? document.child(index, of: parent.value)
            : shownChildren(of: parent.value)[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let document, let item = item as? QuickViewJSONItem,
              document.kind(of: item.value).isContainer
        else { return false }
        return filter == nil
            ? document.childCount(of: item.value) > 0
            : !shownChildren(of: item.value).isEmpty
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let item = item as? QuickViewJSONItem, let tableColumn else { return nil }
        let cell = outlineView.makeView(withIdentifier: QuickViewTableCell.identifier, owner: nil)
            as? QuickViewTableCell ?? QuickViewTableCell()
        let inKeys = tableColumn.identifier == Self.keyColumn
        let label = inKeys ? keyLabel(for: item.value) : valueLabel(for: item.value)
        cell.show(
            label.text,
            font: zoomedFont,
            color: label.color,
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

    struct Label {
        let text: String
        let color: NSColor
        /// The part of `text` the filter reads, where a match is marked: all of a key, a number or a
        /// word, a string inside its quotes, and nothing of an index, `$` or a count.
        var searched: Range<String.Index>?
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

    /// A member's key; an element's index, dimmed, as `[3]`; and for a file that is one scalar, `$`.
    func keyLabel(for value: Int) -> Label {
        guard let document else { return Label(text: "", color: .labelColor) }
        if let key = document.key(of: value) {
            // An empty key is legal JSON, and a blank cell would read as a missing one.
            return key.isEmpty
                ? Label(text: "\"\"", color: .secondaryLabelColor)
                : Label(text: key, color: .labelColor, searched: key.startIndex..<key.endIndex)
        }
        if document.parent(of: value) != nil || document.roots.count > 1 {
            return Label(text: "[\(document.position(of: value))]", color: .secondaryLabelColor)
        }
        return Label(text: "$", color: .secondaryLabelColor)
    }

    /// A string in quotes, a number or a word as written, each in the source view's color for it; a
    /// container as how many values it holds, `{3}` or `[12]`, with `…` when the read limit cut it.
    func valueLabel(for value: Int) -> Label {
        guard let document else { return Label(text: "", color: .labelColor) }
        let kind = document.kind(of: value)
        switch kind {
        case .object, .array:
            let count = "\(document.childCount(of: value))\(document.isIncomplete(value) ? "…" : "")"
            return Label(
                text: kind == .object ? "{\(count)}" : "[\(count)]",
                color: .secondaryLabelColor
            )
        case .string:
            let text = "\"\(document.scalarText(of: value, byteLimit: Self.cellTextLimit))\""
            return Label(
                text: text,
                color: SyntaxTheme.string,
                searched: text.index(after: text.startIndex)..<text.index(before: text.endIndex)
            )
        case .number, .boolean, .null:
            let text = document.scalarText(of: value)
            return Label(
                text: text,
                color: kind == .number ? SyntaxTheme.number : SyntaxTheme.keyword,
                searched: text.startIndex..<text.endIndex
            )
        }
    }
}
