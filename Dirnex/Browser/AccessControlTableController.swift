import AppKit
import DirnexCore

/// The Sharing tab's ACL list (PLAN.md §M14 Slice 4) — the entries **in evaluation order**, and the
/// editor that adds, removes, reorders and rewrites them.
///
/// Its own controller from the start, as PLAN.md §M14 Slice 4 required: a panel this dense arrives at
/// all three SwiftLint ceilings at once if it is one type, and this is the object the editor grew
/// from. The per-entry detail is a second object again (``AccessControlEntryEditor``), split by the
/// same rule.
///
/// **A list, never a set, and never sorted.** macOS evaluates entries top to bottom and takes the
/// first that decides, so a deny placed before an allow is a different ACL from the pair reversed.
/// The order column is not decoration — it is the thing that gives the rows their meaning, and an
/// M14 exit criterion is that what Dirnex shows matches `ls -le`'s order exactly. Reordering is
/// therefore a first-class edit with its own buttons and its own tested core function
/// (``AccessControlList/moving(from:to:)``), not an array shuffle in a click handler.
@MainActor
final class AccessControlTableController: NSObject {
    /// The working list the editor mutates. ``AttributesController`` reads it at Save and compares it
    /// with what was read, so an untouched list is never written — the diff contract the whole panel
    /// rests on, applied to the one thing that is not a field.
    private(set) var list: AccessControlList

    /// The item's kind, which decides how the four aliased rights are spelled (`read` on a file is
    /// `list` on a folder) and how many are offered. The stored token is the same either way.
    private let kind: FileEntry.Kind
    private let canEdit: Bool

    /// Something about the list changed — the panel refreshes Save's enablement.
    var onChange: (() -> Void)?

    /// Named `entryTable` rather than `tableView`: a stored `tableView` on a type that also conforms
    /// to `NSTableViewDelegate` resolves, in a *companion file*, to the delegate method of that name
    /// instead of the property (docs/NOTES.md §"Lint ceilings"). Sidestepped rather than debugged.
    private let entryTable = NSTableView()
    private let editor: AccessControlEntryEditor
    private var removeButton: NSButton?
    private var moveUpButton: NSButton?
    private var moveDownButton: NSButton?
    private var emptyNote: NSView?

    init(list: AccessControlList, kind: FileEntry.Kind, canEdit: Bool) {
        self.list = list
        self.kind = kind
        self.canEdit = canEdit
        editor = AccessControlEntryEditor(kind: kind, canEdit: canEdit)
        super.init()
        editor.onEdit = { [weak self] entry in self?.replaceSelected(with: entry) }
    }

    /// Whether every entry actually decides something.
    ///
    /// An entry with no rights is a state the OS stores happily and that allows and denies nothing
    /// (probed: `ls -le` shows `0: group:staff allow`), so the panel refuses to *write* one rather
    /// than quietly saving a row that does nothing. ``AttributesController`` gates Save on this.
    var isValid: Bool { list.entries.allSatisfy(\.isMeaningful) }

    // MARK: - View

    func makeView(width: CGFloat) -> NSView {
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
        entryTable.rowHeight = 20
        entryTable.usesAlternatingRowBackgroundColors = true
        entryTable.allowsColumnResizing = true
        entryTable.dataSource = self
        entryTable.delegate = self

        let scrollView = NSScrollView()
        scrollView.documentView = entryTable
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        var rows: [NSView] = [scrollView]
        if canEdit { rows.append(makeToolbar()) }
        rows.append(makeEmptyNote())
        if canEdit {
            rows.append(AttributeRow.separator())
            rows.append(editor.makeView(width: width - 32))
        }
        rows.append(AttributeRow.note(String(
            localized: """
            Entries apply in the order shown — macOS takes the first one that decides, so a Deny \
            above an Allow wins.
            """,
            comment: "ACL table footnote explaining that entry order is meaningful."
        )))

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.widthAnchor.constraint(equalToConstant: width - 32).isActive = true
        scrollView.heightAnchor.constraint(
            equalToConstant: AttributesControllerLayout.aclTableHeight
        ).isActive = true

        refreshControls()
        editor.show(nil)

        // The pane scrolls, for the reason the form tabs do: an `NSStackView` that cannot fit its
        // arranged views *compresses* them rather than overflowing, which crushed a whole row out of
        // the Permissions tab once already (docs/NOTES.md). The list, its buttons and a 13-checkbox
        // matrix are more content than a fixed tab, in English before any translation.
        return AttributeRow.pane([stack], width: width)
    }

    /// Add / remove / reorder, as a compact row of square buttons under the list.
    private func makeToolbar() -> NSView {
        let add = button("plus", action: #selector(addEntry(_:)), label: String(
            localized: "Add an entry",
            comment: "Accessibility label for the button that adds an ACL entry."
        ))
        let remove = button("minus", action: #selector(removeEntry(_:)), label: String(
            localized: "Remove the selected entry",
            comment: "Accessibility label for the button that removes an ACL entry."
        ))
        let up = button("chevron.up", action: #selector(moveUp(_:)), label: String(
            localized: "Move the entry earlier",
            comment: "Accessibility label: move an ACL entry up, so it is evaluated sooner."
        ))
        let down = button("chevron.down", action: #selector(moveDown(_:)), label: String(
            localized: "Move the entry later",
            comment: "Accessibility label: move an ACL entry down, so it is evaluated later."
        ))
        removeButton = remove
        moveUpButton = up
        moveDownButton = down

        let row = NSStackView(views: [add, remove, up, down])
        row.orientation = .horizontal
        row.spacing = 6
        return row
    }

    private func button(_ symbol: String, action: Selector, label: String) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
            target: self,
            action: action
        )
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        // A glyph-only control is silent to VoiceOver and has no room for prose, so the words live in
        // the tooltip and the accessibility label — every language's fuller phrasing fits both
        // (docs/NOTES.md — the shortcut recorder's pill).
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func makeEmptyNote() -> NSView {
        let note = AttributeRow.note(String(
            localized: """
            No access control list. This item’s permissions are exactly the owner, group and mode \
            bits shown under Permissions.
            """,
            comment: "Shown in the Sharing tab when the item carries no ACL."
        ))
        emptyNote = note
        return note
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        entryTable.addTableColumn(column)
    }

    // MARK: - Editing

    /// A new entry starts as an **allow** with one right rather than an empty one, so the row it adds
    /// is meaningful the moment it appears — an entry with no rights decides nothing and cannot be
    /// saved (``isValid``), and a default the user has to repair before Save works is a worse
    /// starting point than one they can narrow. `read` is the right that reads as "List" on a folder,
    /// which is the mildest thing an entry can say in either spelling.
    @objc private func addEntry(_ sender: Any?) {
        guard let subject = defaultSubject() else { return }
        list.entries.append(
            ACLEntry(subject: subject, disposition: .allow, rights: [.read])
        )
        reload(selecting: list.entries.count - 1)
    }

    @objc private func removeEntry(_ sender: Any?) {
        let row = entryTable.selectedRow
        guard list.entries.indices.contains(row) else { return }
        list.entries.remove(at: row)
        reload(selecting: min(row, list.entries.count - 1))
    }

    @objc private func moveUp(_ sender: Any?) { move(by: -1) }
    @objc private func moveDown(_ sender: Any?) { move(by: 1) }

    private func move(by offset: Int) {
        let row = entryTable.selectedRow
        let destination = row + offset
        guard list.entries.indices.contains(row), list.entries.indices.contains(destination) else {
            return
        }
        list = list.moving(from: row, to: destination)
        reload(selecting: destination)
    }

    private func replaceSelected(with entry: ACLEntry) {
        let row = entryTable.selectedRow
        guard list.entries.indices.contains(row), list.entries[row] != entry else { return }
        list.entries[row] = entry
        // Redraw the row rather than the table: a full `reloadData` drops the selection, and the
        // selection is what the detail editor is editing (docs/NOTES.md — a bare reload drops the
        // pane's cursor for the same reason).
        entryTable.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integersIn: 0..<entryTable.numberOfColumns)
        )
        onChange?()
    }

    /// The account a new entry names before the user picks one: the current user, who is the one
    /// subject an owner can always write an entry for.
    private func defaultSubject() -> ACLSubject? {
        let uid = getuid()
        guard let name = IdentityDirectory.userName(for: uid) else { return nil }
        return ACLIdentity.subject(for: IdentityRecord(name: name, numericID: uid), kind: .user)
    }

    private func reload(selecting row: Int) {
        entryTable.reloadData()
        if list.entries.indices.contains(row) {
            entryTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        refreshControls()
        editor.show(list.entries.indices.contains(row) ? list.entries[row] : nil)
        onChange?()
    }

    /// The buttons that need a selection, and the empty-state note, follow the list's actual state.
    private func refreshControls() {
        let row = entryTable.selectedRow
        let hasSelection = list.entries.indices.contains(row)
        removeButton?.isEnabled = hasSelection
        moveUpButton?.isEnabled = hasSelection && row > 0
        moveDownButton?.isEnabled = hasSelection && row < list.entries.count - 1
        emptyNote?.isHidden = !list.isEmpty
    }
}

// MARK: - Table

extension AccessControlTableController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { list.entries.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = entryTable.selectedRow
        editor.show(list.entries.indices.contains(row) ? list.entries[row] : nil)
        refreshControls()
    }

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
        // An inherited entry came from a folder above and is not this item's to edit in place, so it
        // reads as secondary — the same distinction the editor enforces by disabling its controls.
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

    /// The account, plus the marker that it was handed down by a parent folder. An entry whose GUID
    /// answers to no account shows the GUID, exactly as `ls -le` does.
    private func subjectDescription(_ entry: ACLEntry) -> String {
        let name = entry.subject.displayName
        guard entry.isInherited else { return name }
        return String(
            localized: "\(name) (inherited)",
            comment: "ACL row subject that a parent folder handed down; %@ is the account name."
        )
    }

    /// The rights, with the inheritance controls appended when the entry carries any — they change
    /// what the entry *does* to new children, so they belong beside the rights rather than hidden.
    /// An entry with no rights says so in words rather than showing an empty cell that reads as a
    /// rendering bug.
    private func rightsDescription(_ entry: ACLEntry) -> String {
        guard entry.isMeaningful else {
            return String(
                localized: "Nothing — this entry has no effect",
                comment: "ACL row shown for an entry that carries no rights at all."
            )
        }
        let rights = AttributeFormatting.rights(of: entry, on: kind)
        guard let inheritance = AttributeFormatting.inheritance(of: entry) else { return rights }
        return String(
            localized: "\(rights) — \(inheritance)",
            comment: "ACL row: %1$@ is the rights list, %2$@ the inheritance flags."
        )
    }
}
