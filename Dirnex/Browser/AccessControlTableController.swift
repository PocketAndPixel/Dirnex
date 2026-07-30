import AppKit
import DirnexCore

/// The Sharing tab's ACL list (PLAN.md §M14 Slice 4) — the entries **in evaluation order**.
///
/// Its own controller from the start, as PLAN.md §M14 Slice 4 requires: the editor grows from here,
/// and a panel this dense arrives at all three SwiftLint ceilings at once if it is one type.
///
/// **A list, never a set, and never sorted.** macOS evaluates entries top to bottom and takes the
/// first that decides, so a deny placed before an allow is a different ACL from the pair reversed.
/// The order column is not decoration — it is the thing that gives the rows their meaning, and an
/// M14 exit criterion is that what Dirnex shows matches `ls -le`'s order exactly.
@MainActor
final class AccessControlTableController: NSObject {
    private let list: AccessControlList
    /// The item's kind, which decides how the four aliased rights are spelled (`read` on a file is
    /// `list` on a folder). The stored token is the same either way.
    private let kind: FileEntry.Kind

    private let tableView = NSTableView()

    init(list: AccessControlList, kind: FileEntry.Kind) {
        self.list = list
        self.kind = kind
        super.init()
    }

    func makeView(width: CGFloat) -> NSView {
        guard !list.isEmpty else { return makeEmptyView(width: width) }

        addColumn("order", title: "#", width: 24)
        addColumn(
            "subject",
            title: String(
                localized: "Who",
                comment: "ACL table column header: the user or group the entry is about."
            ),
            width: 150
        )
        addColumn(
            "disposition",
            title: String(
                localized: "Type",
                comment: "ACL table column header: whether the entry allows or denies."
            ),
            width: 60
        )
        addColumn(
            "rights",
            title: String(
                localized: "Permissions",
                comment: "ACL table column header: the rights the entry covers."
            ),
            width: 280
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

        let note = AttributeRow.note(String(
            localized: """
            Entries apply in the order shown — macOS takes the first one that decides, so a Deny \
            above an Allow wins.
            """,
            comment: "ACL table footnote explaining that entry order is meaningful."
        ))

        let stack = NSStackView(views: [scrollView, note])
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

    private func makeEmptyView(width: CGFloat) -> NSView {
        AttributeRow.pane(
            [AttributeRow.note(String(
                localized: """
                No access control list. This item’s permissions are exactly the owner, group and \
                mode bits shown under Permissions.
                """,
                comment: "Shown in the Sharing tab when the item carries no ACL."
            ))],
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

extension AccessControlTableController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { list.entries.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let column = tableColumn, list.entries.indices.contains(row) else { return nil }
        let entry = list.entries[row]

        let label = NSTextField(labelWithString: text(
            for: entry,
            column: column.identifier.rawValue,
            row: row
        ))
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.lineBreakMode = .byTruncatingTail
        // An inherited entry came from a folder above and is not this item's to edit, so it reads as
        // secondary — the one visual distinction the read-only pass can carry, and the one the
        // editor will build its "not casually edited in place" rule on.
        if entry.isInherited { label.textColor = .secondaryLabelColor }
        if column.identifier.rawValue == "disposition" {
            label.textColor = entry.disposition == .deny ? .systemRed : label.textColor
        }
        return label
    }

    private func text(for entry: ACLEntry, column: String, row: Int) -> String {
        switch column {
        case "order":
            return String(row + 1)
        case "subject":
            return subjectDescription(entry)
        case "disposition":
            return AttributeFormatting.disposition(entry.disposition)
        default:
            return rightsDescription(entry)
        }
    }

    /// The account, plus the marker that it was handed down by a parent folder.
    private func subjectDescription(_ entry: ACLEntry) -> String {
        let name = entry.subject.name
        guard entry.isInherited else { return name }
        return String(
            localized: "\(name) (inherited)",
            comment: "ACL row subject that a parent folder handed down; %@ is the account name."
        )
    }

    /// The rights, with the inheritance controls appended when the entry carries any — they change
    /// what the entry *does* to new children, so they belong beside the rights rather than hidden.
    private func rightsDescription(_ entry: ACLEntry) -> String {
        let rights = AttributeFormatting.rights(of: entry, on: kind)
        guard let inheritance = AttributeFormatting.inheritance(of: entry) else { return rights }
        return String(
            localized: "\(rights) — \(inheritance)",
            comment: "ACL row: %1$@ is the rights list, %2$@ the inheritance flags."
        )
    }
}
