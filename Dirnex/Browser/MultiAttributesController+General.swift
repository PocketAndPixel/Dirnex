import AppKit
import DirnexCore

/// The multi-selection General tab: what the selection is, where it lives, and the three dates
/// (PLAN.md §M14 Slice 4).
///
/// Dates over a selection have no natural "mixed" control — an `NSDatePicker` always shows *some*
/// instant — so each is gated by a **Change** checkbox. Off (the default) means "leave every item's
/// own date"; on means "set this instant on all of them". That keeps the diff-based promise the whole
/// feature rests on: a date the user did not opt into is never written.
extension MultiAttributesController {
    func makeGeneralTab() -> NSView {
        var rows: [NSView] = []

        if let parent = MultiAttributeSummary.commonParent(of: items) {
            rows.append(AttributeRow.make(
                label: String(
                    localized: "Where:",
                    comment: "Info panel field label: the folder the items are in."
                ),
                value: parent
            ))
        }

        if !rows.isEmpty { rows.append(AttributeRow.separator()) }
        rows.append(contentsOf: [
            makeDateRow(
                .creation,
                label: String(
                    localized: "Created:",
                    comment: "Info panel field label: the item's birth time (st_birthtime)."
                )
            ),
            makeDateRow(
                .modification,
                label: String(
                    localized: "Modified:",
                    comment: "Info panel field label: last content modification (st_mtime)."
                )
            ),
            makeDateRow(
                .access,
                label: String(
                    localized: "Last opened:",
                    comment: "Info panel field label: last access time (st_atime)."
                )
            )
        ])

        if canEdit {
            rows.append(AttributeRow.note(String(
                localized: """
                Tick a date to set it on every selected item; leave it unticked to keep each item’s \
                own.
                """,
                comment: "Info panel note explaining the multi-selection date checkboxes."
            )))
        } else {
            rows.append(makeNotOwnerNote())
        }

        return AttributeRow.pane(rows, width: MultiAttributesController.contentWidth)
    }

    /// A `Label:  [✓ Change]  <picker>` row. The picker starts at the first item's value — a
    /// meaningful anchor to nudge from — and is live only while **Change** is ticked, so nothing is
    /// written unless the user opts in.
    private func makeDateRow(_ kind: DateKind, label: String) -> NSView {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.dateValue = anchorDate(kind)
        picker.isEnabled = false
        picker.target = self
        picker.action = #selector(editChanged(_:))
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let enable = NSButton(
            checkboxWithTitle: String(
                localized: "Change",
                comment: "Checkbox that opts a date into a multi-selection edit."
            ),
            target: self,
            action: #selector(dateEnableChanged(_:))
        )
        enable.state = .off
        enable.isEnabled = canEdit

        dateRows.append(DateRow(enable: enable, picker: picker, kind: kind))

        let controls = NSStackView(views: [enable, picker])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        return AttributeRow.make(label: label, view: controls)
    }

    /// The value a date picker starts at: the first item's own date for that field. Only a starting
    /// point — nothing is written until its Change box is ticked.
    private func anchorDate(_ kind: DateKind) -> Date {
        guard let first = items.first?.attributes else { return Date() }
        switch kind {
        case .access: return first.accessDate
        case .modification: return first.modificationDate
        case .creation: return first.creationDate
        }
    }

    /// A Change checkbox toggled: enable or disable its picker, then refresh Save like any other edit.
    @objc func dateEnableChanged(_ sender: Any?) {
        for row in dateRows {
            row.picker.isEnabled = canEdit && row.enable.state == .on
        }
        refreshSaveEnabled()
    }
}

/// The header and summary text for a multi-selection — pure formatting, kept out of the controller so
/// it is testable without a view.
enum MultiAttributeSummary {
    /// `5 items` — reuses the pane status line's already-translated plural key, so no new catalog
    /// entry is owed.
    static func title(of items: [MultiAttributesController.Item]) -> String {
        let count = items.count
        return String(localized: "\(count) items")
    }

    /// The total size of the selected files, as the header's subtitle. Folders are not sized (that
    /// would need a recursive walk), so this is the bytes of the files in the selection.
    static func subtitle(of items: [MultiAttributesController.Item]) -> String {
        let bytes = items.reduce(Int64(0)) { total, item in
            total + (item.entry.kind == .file ? item.entry.byteSize : 0)
        }
        return AttributeFormatting.byteSize(bytes)
    }

    /// The folder every item is in, when they share one — otherwise `nil`, since the selection spans
    /// directories and there is no single "Where".
    static func commonParent(of items: [MultiAttributesController.Item]) -> String? {
        let parents = Set(items.map { $0.entry.path.parent?.path })
        // `.first` on a `Set<String?>` is `String??`; binding it unwraps the outer optional, leaving
        // the inner `String?` (nil for a root item with no parent).
        guard parents.count == 1, let only = parents.first else { return nil }
        return only
    }
}
