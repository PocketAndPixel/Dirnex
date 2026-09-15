import AppKit

/// One cell: a single-line label, centered vertically, cut off with an ellipsis, and floating its
/// whole value on hover when it was cut.
@MainActor
final class QuickViewTableCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("QuickViewTableCell")
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.allowsExpansionToolTips = true
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A line break inside a quoted value would push the rest of it below the row, so a cell draws
    /// one as a space; the strip shows the value as written.
    func show(_ value: String, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
        let singleLine = value.contains(where: \.isNewline)
            ? value.split(whereSeparator: \.isNewline).joined(separator: " ")
            : value
        label.stringValue = singleLine
        label.font = font
        label.textColor = color
        label.alignment = alignment
    }
}

/// The table itself, which puts the selected rows on the pasteboard as tab-separated text — what a
/// spreadsheet reads back into cells.
@MainActor
final class QuickViewDataTableView: NSTableView, NSMenuItemValidation {
    var copiedText: ((IndexSet) -> String?)?
    /// Where ⌘C writes. The general pasteboard, except in a test, which must not overwrite the
    /// clipboard of whoever is running it.
    var pasteboard = NSPasteboard.general

    @objc func copy(_ sender: Any?) {
        guard let text = copiedText?(selectedRowIndexes), !text.isEmpty else {
            NSSound.beep()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: .tabularText)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(copy(_:)) else { return true }
        return !selectedRowIndexes.isEmpty
    }
}
