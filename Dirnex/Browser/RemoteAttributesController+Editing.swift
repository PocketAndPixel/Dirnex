import AppKit
import DirnexCore

/// Get Info's **write** half for a row that is not on this Mac (PLAN.md §M25 Slice 5).
///
/// Two fields, and the shortness of that list is the protocol rather than a first pass — see
/// ``RemoteAttributeField``. What a given account will actually take is narrower still and is asked
/// of the connection, so the controls a panel draws are the ones pressing Save can do something
/// with: a mode over SFTP, a mode and a modification time over FTP, nothing at all over an object
/// store or an archive.
///
/// **A clean answer from the server is not proof the write landed**, which is the finding this half
/// is built around and the reason Save ends in a re-read. Measured 2026-08-28 against a real `sshd`:
/// `chmod 2755` on a file whose group the account is not a member of exits **0**, prints nothing,
/// and stores `100755` — set-gid silently gone. So the panel reports what the item *reads as*
/// afterwards, never what it sent (``RemoteAttributeVerdict``).
///
/// **Not undoable, and the panel says so.** ⌘Z reverses an attribute change through
/// `FileAttributeIO`'s syscalls (`UndoStep.restoreAttributes`), which is a local-only executor; a
/// backend-driven step is its own piece of work and is not in this pass. Stating that in the note is
/// what keeps it from being a silent asymmetry with the local panel (PLAN.md §6: non-reversible
/// operations are marked, never silently dropped).
extension RemoteAttributesController {
    /// A grid of the nine `rwx` bits, plus the three special ones — the twelve `chmod` carries over
    /// the wire, which is strictly more than a transfer's preserve flag can express.
    ///
    /// Its own grid rather than the single-item panel's, for the reason that panel's and the bulk
    /// one's are already two: they mean different things. `AttributesController`'s is wired to a
    /// live `lstat` snapshot, a privilege escalation and a BSD flags word, and
    /// `MultiAttributesController`'s is tri-state because a marked set has mixed values. This one
    /// has a mode and nothing else, and its boxes answer one question — what would `chmod` be sent.
    func makeModeEditor() -> NSView {
        let current = POSIXPermissions(rawValue: entry.permissions ?? 0)
        let columns: [NSView] = POSIXPermissions.Class.allCases.map { cls in
            var views: [NSView] = [gridHeading(cls)]
            for access in POSIXPermissions.Access.allCases {
                let box = checkbox(title: accessTitle(access), isOn: current[cls, access])
                modeBoxes.append(ModeBox(box: box, cls: cls, access: access))
                views.append(box)
            }
            let column = NSStackView(views: views)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            return column
        }
        let grid = NSStackView(views: columns)
        grid.orientation = .horizontal
        grid.alignment = .top
        grid.spacing = 20

        let stack = NSStackView(views: [grid, makeSpecialBitsRow(current)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        return stack
    }

    /// Set-UID, set-GID and sticky. Worth their own row here rather than being folded into the octal
    /// echo, because `chmod` over the wire is the **only** route to them — the transfer's preserve
    /// flag drops all three silently — so this is the one place a user can put one back on a copy.
    private func makeSpecialBitsRow(_ current: POSIXPermissions) -> NSView {
        let boxes = [
            (
                String(localized: "Set UID", comment: "Mode bit: run as the file's owner."),
                current.setUserID,
                SpecialBit.setUserID
            ),
            (
                String(localized: "Set GID", comment: "Mode bit: run as the file's group."),
                current.setGroupID,
                SpecialBit.setGroupID
            ),
            (
                String(
                    localized: "Sticky",
                    comment: "Mode bit: restrict deletion in a folder to each item's owner."
                ),
                current.sticky,
                SpecialBit.sticky
            )
        ].map { title, isOn, bit -> NSButton in
            let box = checkbox(title: title, isOn: isOn)
            specialBoxes.append(SpecialBox(box: box, bit: bit))
            return box
        }
        let row = NSStackView(views: boxes)
        row.orientation = .horizontal
        row.spacing = 16
        return row
    }

    /// The date control, live only over a connection with a verb that writes one.
    ///
    /// `NSDatePicker` resolves to whole seconds where a real timestamp does not, so the panel
    /// compares against the value the control was **given** rather than against the entry — the
    /// trap `AttributesController` already paid for, where reading it back unconditionally lit up
    /// Save with nothing edited (docs/NOTES.md ▸ ACLs and file attributes).
    func makeDateEditor() -> NSView {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.dateValue = entry.modificationDate
        picker.target = self
        picker.action = #selector(editChanged(_:))
        modificationPicker = picker
        pickerBaseline = picker.dateValue
        return picker
    }

    private func gridHeading(_ cls: POSIXPermissions.Class) -> NSTextField {
        let title: String
        switch cls {
        case .owner:
            title = String(
                localized: "Owner", comment: "Info panel mode grid column: the owning user's bits."
            )
        case .group:
            title = String(
                localized: "Group", comment: "Info panel mode grid column: the owning group's bits."
            )
        case .other:
            title = String(
                localized: "Everyone",
                comment: "Info panel mode grid column: the bits for everybody else."
            )
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func accessTitle(_ access: POSIXPermissions.Access) -> String {
        switch access {
        case .read: String(localized: "Read", comment: "Mode bit: permission to read.")
        case .write: String(localized: "Write", comment: "Mode bit: permission to write.")
        case .execute: String(
                localized: "Execute",
                comment: "Mode bit: permission to run a file, or to traverse a folder."
            )
        }
    }

    private func checkbox(title: String, isOn: Bool) -> NSButton {
        let box = NSButton(
            checkboxWithTitle: title,
            target: self,
            action: #selector(editChanged(_:))
        )
        box.state = isOn ? .on : .off
        return box
    }

    // MARK: - Reading the controls back

    /// The mode the controls currently spell.
    var editedPermissions: POSIXPermissions {
        var mode = POSIXPermissions(rawValue: 0)
        for entry in modeBoxes where entry.box.state == .on {
            mode[entry.cls, entry.access] = true
        }
        for entry in specialBoxes where entry.box.state == .on {
            switch entry.bit {
            case .setUserID: mode.setUserID = true
            case .setGroupID: mode.setGroupID = true
            case .sticky: mode.sticky = true
            }
        }
        return mode
    }

    /// What Save would send — empty when nothing was touched.
    ///
    /// Built through the core's own rule rather than by reading the controls directly, so a field
    /// this connection cannot change is dropped here even if a control for it were somehow live.
    var pendingChange: RemoteAttributeChange {
        RemoteAttributeChange.between(
            current: entry,
            permissions: modeBoxes.isEmpty ? nil : editedPermissions,
            modificationTime: modificationPicker?.dateValue,
            editable: editability
        )
    }

    @objc func editChanged(_ sender: Any?) {
        refreshModeEcho()
        saveButton?.isEnabled = !pendingChange.isEmpty
    }

    /// Keep the `Permissions:` line agreeing with the boxes above it, so the panel never shows a
    /// mode the grid contradicts.
    private func refreshModeEcho() {
        guard let modeValueField, !modeBoxes.isEmpty else { return }
        modeValueField.stringValue = AttributeFormatting.modeDescription(editedPermissions)
    }
}
