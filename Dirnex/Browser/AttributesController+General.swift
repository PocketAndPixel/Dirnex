import AppKit
import DirnexCore

/// The General tab: where the item is, and the three timestamps (PLAN.md §M14 Slice 4).
///
/// The dates are the reason this tab exists separately from Permissions. macOS keeps three and shows
/// two; the birth time in particular is reachable only through `setattrlist` and is displayed by
/// almost nothing, so having it here is already an answer Dirnex could not give before.
///
/// **All three are editable for the item's owner**, unprivileged — `utimes` for access and
/// modification, `setattrlist(ATTR_CMN_CRTIME)` for the birth time — and they commit on the same
/// **Save** as the mode bits, through the same tested plan. The one trap is not in the syscalls but
/// in the control: an `NSDatePicker` resolves to whole seconds and a real timestamp does not, which
/// is what ``AttributesController/DateField/initial`` exists to absorb.
extension AttributesController {
    func makeGeneralTab() -> NSView {
        var rows: [NSView] = [
            AttributeRow.make(
                label: String(
                    localized: "Where:",
                    comment: "Info panel field label: the folder the item is in."
                ),
                value: snapshot.entry.path.parent?.path ?? snapshot.entry.path.path
            )
        ]

        if let destination = snapshot.entry.symlinkDestination {
            rows.append(AttributeRow.make(
                label: String(
                    localized: "Points to:",
                    comment: "Info panel field label: what a symbolic link resolves to."
                ),
                value: destination
            ))
        }

        rows.append(contentsOf: [
            AttributeRow.separator(),
            AttributeRow.make(
                label: String(
                    localized: "Created:",
                    comment: "Info panel field label: the item's birth time (st_birthtime)."
                ),
                view: makeDateField(.creation, snapshot.attributes.creationDate)
            ),
            AttributeRow.make(
                label: String(
                    localized: "Modified:",
                    comment: "Info panel field label: last content modification (st_mtime)."
                ),
                view: makeDateField(.modification, snapshot.attributes.modificationDate)
            ),
            AttributeRow.make(
                label: String(
                    localized: "Last opened:",
                    comment: "Info panel field label: last access time (st_atime)."
                ),
                view: makeDateField(.access, snapshot.attributes.accessDate)
            )
        ])

        if !canEdit {
            rows.append(makeNotOwnerNote())
        }

        if snapshot.isSymlink {
            rows.append(AttributeRow.note(String(
                localized: """
                This is a symbolic link, so everything shown here describes the link itself — not \
                the item it points to.
                """,
                comment: "Info panel note explaining that a symlink's own attributes are shown."
            )))
        }

        return AttributeRow.pane(rows, width: AttributesController.contentWidth)
    }

    /// One timestamp control, registered so ``rebuildWorkingFromControls()`` can read it back.
    ///
    /// A stepper-and-field picker rather than the graphical calendar: these are exact instants a user
    /// corrects, not a day they choose, and the field form is the only one that offers seconds. Its
    /// formatting follows the current locale for free, as every other date in the app does.
    ///
    /// Disabled rather than replaced by text when the item is not the user's, matching how the mode
    /// grid degrades — one layout in both states, so nothing shifts and no row can go missing.
    private func makeDateField(_ kind: DateFieldKind, _ value: Date) -> NSView {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.dateValue = value
        picker.isEnabled = canEdit
        picker.target = self
        picker.action = #selector(editChanged(_:))
        picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // `dateValue` rather than `value`: the picker quantizes what it is given, and the whole point
        // of `initial` is to compare against what the control actually holds.
        dateFields.append(DateField(picker: picker, kind: kind, initial: picker.dateValue))
        return picker
    }
}
