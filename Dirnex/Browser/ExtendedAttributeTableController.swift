import AppKit
import DirnexCore

/// The Attributes tab's extended-attribute list (PLAN.md §M14 Slice 4).
///
/// **`com.apple.provenance` is already filtered out upstream, and that is the whole reason this is a
/// list rather than a row badge.** It is on essentially every file on a modern Mac, so "this file
/// has extended attributes" carries no information — the M14 probe killed the badge before it was
/// built. What is worth showing is a *named* attribute: `com.apple.quarantine` above all, and the
/// where-from URLs beside it.
@MainActor
final class ExtendedAttributeTableController: NSObject {
    private let attributes: [ExtendedAttribute]
    private let tableView = NSTableView()

    init(attributes: [ExtendedAttribute]) {
        self.attributes = attributes
        super.init()
    }

    func makeView(width: CGFloat) -> NSView {
        guard !attributes.isEmpty else { return makeEmptyView(width: width) }

        addColumn(
            "name",
            title: String(
                localized: "Name",
                comment: "Extended attributes table column header: the attribute's name."
            ),
            width: 240
        )
        addColumn(
            "size",
            title: String(
                localized: "Size",
                comment: "Extended attributes table column header: the value's length in bytes."
            ),
            width: 70
        )
        addColumn(
            "value",
            title: String(
                localized: "Value",
                comment: "Extended attributes table column header: a preview of the value."
            ),
            width: 220
        )
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.dataSource = self
        tableView.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [scrollView, AttributeRow.note(hiddenNote())])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: width),
            scrollView.widthAnchor.constraint(equalToConstant: width - 32),
            scrollView.heightAnchor.constraint(
                equalToConstant: AttributesControllerLayout.tableHeight
            )
        ])
        return container
    }

    /// Said once, plainly, so a user comparing this list against `xattr -l` is not left wondering
    /// where the extra line went.
    private func hiddenNote() -> String {
        String(
            localized: """
            “com.apple.provenance” is not listed: macOS puts it on nearly every file, so it says \
            nothing about this one.
            """,
            comment: "Footnote explaining the one extended attribute the panel filters out."
        )
    }

    private func makeEmptyView(width: CGFloat) -> NSView {
        AttributeRow.pane(
            [AttributeRow.note(String(
                localized: "No extended attributes.",
                comment: "Shown when an item carries no extended attributes worth listing."
            )), AttributeRow.note(hiddenNote())],
            width: width
        )
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }
}

// MARK: - Table

extension ExtendedAttributeTableController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { attributes.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let column = tableColumn, attributes.indices.contains(row) else { return nil }
        let attribute = attributes[row]

        let text: String
        var monospaced = false
        switch column.identifier.rawValue {
        case "name":
            text = attribute.name
        case "size":
            text = AttributeFormatting.byteSize(Int64(attribute.data.count))
        default:
            text = AttributeFormatting.value(of: attribute)
            monospaced = attribute.value == .binary
        }

        let label = NSTextField(labelWithString: text)
        label.font = monospaced
            ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.isSelectable = true
        return label
    }
}
