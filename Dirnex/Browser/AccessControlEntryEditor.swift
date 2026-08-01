import AppKit
import DirnexCore

/// The detail half of the Sharing tab: everything about the **one** ACL entry selected in the list
/// above it (PLAN.md §M14 Slice 4) — who it is about, whether it allows or denies, and the rights
/// matrix.
///
/// Master–detail rather than a checkbox grid in the table, because PLAN.md's two requirements pull in
/// opposite directions: the entries are *a list whose order is meaning*, and each entry carries **12
/// rights for a file, 13 + 4 inheritance flags for a directory**. Seventeen checkbox columns is not a
/// table anyone can read; the list stays a list, and the selected row's rights get the room they need.
///
/// The matrix switches on the item's kind rather than showing everything, which is a correctness
/// property and not a tidiness one: the four aliased bits are *relabelled* on a directory (`read` is
/// "List", `write` is "Add File"), so a folder offering "Read" would name a bit that every other tool
/// on the Mac calls something else, and `delete_child` does not apply to a file at all.
@MainActor
final class AccessControlEntryEditor {
    /// The item's kind, which decides both the rights offered and how four of them are spelled.
    private let kind: FileEntry.Kind
    private let canEdit: Bool

    /// The edited entry, handed back whole. The caller owns the list and replaces the row.
    var onEdit: ((ACLEntry) -> Void)?

    private let subjectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dispositionControl = NSSegmentedControl()
    private var rightBoxes: [(box: NSButton, right: ACLRight)] = []
    private var inheritanceBoxes: [(box: NSButton, option: ACLInheritance)] = []
    private var inheritedNote: NSView?

    /// The entry being shown, or `nil` when nothing is selected. Held so a checkbox click can rebuild
    /// the whole entry from every control at once — the same "rebuild from all of them" shape the
    /// Permissions tab's mode grid uses, which is what keeps the controls from disagreeing.
    private var entry: ACLEntry?

    init(kind: FileEntry.Kind, canEdit: Bool) {
        self.kind = kind
        self.canEdit = canEdit
    }

    // MARK: - View

    func makeView(width: CGFloat) -> NSView {
        subjectPopup.target = self
        subjectPopup.action = #selector(controlChanged(_:))
        subjectPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dispositionControl.segmentCount = 2
        dispositionControl.setLabel(AttributeFormatting.disposition(.allow), forSegment: 0)
        dispositionControl.setLabel(AttributeFormatting.disposition(.deny), forSegment: 1)
        dispositionControl.trackingMode = .selectOne
        dispositionControl.target = self
        dispositionControl.action = #selector(controlChanged(_:))
        // A segmented control has no line-break escape hatch and simply crushes its cells under a
        // longer translation (docs/NOTES.md — the sync sheet's direction control), so it keeps full
        // compression resistance and the row it sits in gives way elsewhere.
        dispositionControl.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let note = AttributeRow.note(String(
            localized: """
            This entry came from a folder above and is shown as it applies here. Remove it to stop \
            it applying to this item.
            """,
            comment: "Sharing tab note shown when the selected ACL entry is inherited."
        ))
        inheritedNote = note

        var rows: [NSView] = [
            AttributeRow.make(
                label: String(
                    localized: "Who:",
                    comment: "Sharing tab field label: which user or group the ACL entry is about."
                ),
                view: subjectPopup
            ),
            AttributeRow.make(
                label: String(
                    localized: "Type:",
                    comment: "Sharing tab field label: whether the entry allows or denies."
                ),
                view: dispositionControl
            ),
            // The two grids get their caption *above* them and the pane's whole width, rather than
            // the 130 pt label column the rows above use. That is a measurement, not a preference:
            // the checkbox labels are long sentences in several languages, and the label column costs
            // 138 pt the widest of them needs. See ``makeRightsGrid``.
            caption(String(
                localized: "Permissions:",
                comment: "Sharing tab field label: the rights the selected ACL entry covers."
            )),
            makeRightsGrid()
        ]
        if kind == .directory {
            rows.append(caption(String(
                localized: "Inheritance:",
                comment: "Sharing tab field label: which new children the entry propagates to."
            )))
            rows.append(makeInheritanceGrid())
        }
        rows.append(note)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    /// **Two columns, at the pane's full width — both halves of that are measured, not chosen.**
    ///
    /// Measured in the real font over all 14 shipped languages (docs/NOTES.md: don't reason about a
    /// stack's widths, and never off a downsampled screenshot). Three columns need **506 pt** against
    /// the 410 a label column leaves, so English itself clipped "Execute" and "Append" — visible in
    /// this pass's own first screenshot. Two columns in that same 410 fit English at 332 and
    /// **overflow Russian at 436** («Изменять расширенные атрибуты»), with Polish, Dutch and
    /// Ukrainian clearing it by 4 pt — which is not clearance, it is the next translation's bug.
    ///
    /// Dropping the 130 pt label column is what actually buys the room: at the full 548 the worst
    /// language needs 436 and has 112 pt spare. Hence the caption above the grid rather than beside
    /// it, which is the same answer the function bar and the pack sheet arrived at from the other
    /// direction — size to the widest *localized* label, never to the English one.
    private func makeRightsGrid() -> NSView {
        let rights = ACLRight.applicable(to: kind)
        let perColumn = Int((Double(rights.count) / 2.0).rounded(.up))
        return grid(of: rights.map { right in
            let box = checkbox(title: AttributeFormatting.right(right, on: kind))
            rightBoxes.append((box, right))
            return box
        }, perColumn: perColumn, spacing: 16)
    }

    /// The four directory-only inheritance controls, 2 × 2 for the same measured reason: in one row
    /// they need **589 pt in Ukrainian** and 579 in Russian against 548 available, while English fits
    /// at 486 — an overflow no English screenshot can show. `inherited` is deliberately absent: it is
    /// a read-only marker saying where the entry came from, not a control.
    private func makeInheritanceGrid() -> NSView {
        grid(of: ACLInheritance.directoryControls.map { option in
            let box = checkbox(title: AttributeFormatting.inheritanceTitle(option))
            inheritanceBoxes.append((box, option))
            return box
        }, perColumn: 2, spacing: 16)
    }

    /// Lay checkboxes out in columns of `perColumn`, filling each column top to bottom.
    private func grid(of boxes: [NSButton], perColumn: Int, spacing: CGFloat) -> NSView {
        var columns: [NSView] = []
        for start in stride(from: 0, to: boxes.count, by: perColumn) {
            let column = NSStackView(
                views: Array(boxes[start..<min(start + perColumn, boxes.count)])
            )
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            columns.append(column)
        }
        let grid = NSStackView(views: columns)
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.spacing = spacing
        return grid
    }

    /// A caption that sits *above* what it names, for the two grids too wide to keep a label column.
    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func checkbox(title: String) -> NSButton {
        let box = NSButton(
            checkboxWithTitle: title,
            target: self,
            action: #selector(controlChanged(_:))
        )
        box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return box
    }

    // MARK: - Showing a selection

    /// Point the editor at an entry, or at nothing. Everything is disabled when there is no selection
    /// — an editor showing live controls over no row invites an edit that lands nowhere.
    func show(_ entry: ACLEntry?) {
        self.entry = entry
        ACLSubjectPicker.populate(subjectPopup, selecting: entry?.subject)
        dispositionControl.selectedSegment = entry?.disposition == .deny ? 1 : 0
        for (box, right) in rightBoxes {
            box.state = entry?.rights.contains(right) == true ? .on : .off
        }
        for (box, option) in inheritanceBoxes {
            box.state = entry?.inheritance.contains(option) == true ? .on : .off
        }
        // An inherited entry is shown exactly as it applies but is not edited in place: it belongs to
        // a folder above, and rewriting it here would silently fork it from its parent's copy.
        // Removing it is still the user's to do, which is what the note says.
        let editable = canEdit && entry != nil && entry?.isInherited != true
        subjectPopup.isEnabled = editable
        dispositionControl.isEnabled = editable
        for (box, _) in rightBoxes { box.isEnabled = editable }
        for (box, _) in inheritanceBoxes { box.isEnabled = editable }
        inheritedNote?.isHidden = entry?.isInherited != true
    }

    // MARK: - Editing

    /// Any control changed: rebuild the entry from *all* of them at once and hand it back whole.
    ///
    /// The unrecognized rights and flags ride along untouched — a right this build does not model
    /// must survive an edit to its neighbours, or writing the ACL back silently strips a bit a later
    /// macOS added, which is unacceptable for security metadata.
    @objc private func controlChanged(_ sender: Any?) {
        guard var edited = entry, !edited.isInherited else { return }
        if let subject = ACLSubjectPicker.selectedSubject(in: subjectPopup) {
            edited.subject = subject
        }
        edited.disposition = dispositionControl.selectedSegment == 1 ? .deny : .allow
        edited.rights = Set(rightBoxes.filter { $0.box.state == .on }.map(\.right))

        var inheritance = edited.inheritance.intersection(.inherited)
        for (box, option) in inheritanceBoxes where box.state == .on {
            inheritance.insert(option)
        }
        edited.inheritance = inheritance

        entry = edited
        onEdit?(edited)
    }
}
