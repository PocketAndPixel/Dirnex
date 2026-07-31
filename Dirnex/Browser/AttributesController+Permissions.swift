import AppKit
import DirnexCore

/// The Permissions tab: owner, group, the twelve mode bits and the BSD file flags
/// (PLAN.md §M14 Slice 4).
///
/// **Editable in this pass for the item's owner** (mode bits and `UF_*` flags — the commit and undo
/// live in `AttributesController+Editing.swift`). A file the user does not own shows the same grid,
/// disabled, until Slice 5 adds the privileged path; owner and group stay read-only until their own
/// pass. Every checkbox is wired to one `editChanged` handler that rebuilds the working copy, so this
/// file only lays them out and records which bit each one is.
///
/// **The ACL note here is an M14 exit criterion, not decoration.** Adding an ACL does not change the
/// mode bits — probed: a file with an ACL still reads 0644 — so a panel that shows `rw-r--r--` and
/// says nothing else makes a *false* claim about the file's permissions on precisely the files where
/// the answer is not the mode. Whenever an ACL is present this tab says so and points at the tab
/// that lists it.
extension AttributesController {
    func makePermissionsTab() -> NSView {
        var rows: [NSView] = []

        if !canEdit {
            rows.append(makeNotOwnerNote())
        }

        rows.append(contentsOf: [
            AttributeRow.make(
                label: String(
                    localized: "Owner:",
                    comment: "Info panel field label: the owning user (st_uid)."
                ),
                value: snapshot.ownerDescription
            ),
            AttributeRow.make(
                label: String(
                    localized: "Group:",
                    comment: "Info panel field label: the owning group (st_gid)."
                ),
                view: makeGroupPicker()
            )
        ])

        if canEdit {
            rows.append(AttributeRow.note(String(
                localized: """
                Only an administrator can change an item’s owner, and the groups offered are the \
                ones you belong to.
                """,
                comment: "Info panel note: why Owner is fixed and the group list is short."
            )))
        }

        rows.append(contentsOf: [
            AttributeRow.separator(),
            AttributeRow.make(
                label: String(
                    localized: "Access:",
                    comment: "Info panel field label: the grid of read/write/execute mode bits."
                ),
                view: makePermissionGrid()
            ),
            makeModeRow(),
            AttributeRow.make(
                label: String(
                    localized: "Special:",
                    comment: "Info panel field label: set-uid, set-gid and the sticky bit."
                ),
                view: makeSpecialBitsRow()
            ),
            AttributeRow.separator(),
            AttributeRow.make(
                label: String(
                    localized: "Flags:",
                    comment: "Info panel field label: the BSD file flags (chflags)."
                ),
                view: makeFlagsColumn()
            )
        ])

        if let system = AttributeFormatting.systemFlagsDescription(snapshot.attributes.flags) {
            rows.append(AttributeRow.note(String(
                localized: """
                This item also carries system flags (\(system)). Only an administrator can change \
                those.
                """,
                comment: "Info panel note listing root-only SF_* flags; %@ is their names."
            )))
        }

        if snapshot.hasAccessControlList {
            rows.append(AttributeRow.note(
                String(
                    localized: """
                    These permissions are not the whole story: an access control list also applies \
                    to this item. See the Sharing tab.
                    """,
                    comment: "Info panel warning shown whenever an ACL applies on top of the mode."
                ),
                isWarning: true
            ))
        }

        return AttributeRow.pane(rows, width: AttributesController.contentWidth)
    }

    // MARK: - Ownership

    /// The group popup, offering only what a `chgrp` can actually do.
    ///
    /// **Owner has no popup beside it, and that is the finding rather than an omission.** `chown` to
    /// another user is `EPERM` even on your own file (re-measured 2026-07-31), so a user picker could
    /// never succeed unprivileged — and this panel's own precedent for that is the `SF_*` flags, which
    /// are reported as a note rather than offered as a checkbox because "offering one as a toggle
    /// would promise something the panel cannot do". Slice 5's escalation is what makes owner
    /// reachable; until then the row states the fact.
    ///
    /// The group list is ``IdentityRoster/selectableGroups(from:memberOf:current:)``, which is the
    /// same rule stated as a tested core function: your own groups, plus whatever the item is in now.
    private func makeGroupPicker() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let groups = IdentityRoster.selectableGroups(
            from: IdentityDirectory.groups(),
            memberOf: actor.groupIDs,
            current: snapshot.attributes.groupID
        )
        for group in groups {
            popup.addItem(withTitle: AttributesSnapshot.describe(group.name, id: group.numericID))
            popup.lastItem?.tag = Int(group.numericID)
        }
        popup.selectItem(withTag: Int(snapshot.attributes.groupID))
        popup.isEnabled = canEdit && groups.count > 1
        popup.target = self
        popup.action = #selector(editChanged(_:))
        groupPopup = popup

        // A popup defends its widest item's width; the sheet's width is fixed, so it gives way like
        // every other value in these rows rather than pushing the layout wider.
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return popup
    }

    // MARK: - The mode grid

    /// A read/write/execute column per class of checkboxes — live for the owner, disabled otherwise.
    private func makePermissionGrid() -> NSView {
        let columns: [NSView] = POSIXPermissions.Class.allCases.map { cls in
            var views: [NSView] = [classHeading(cls)]
            for access in POSIXPermissions.Access.allCases {
                views.append(accessCheckbox(cls, access))
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
        return grid
    }

    private func classHeading(_ cls: POSIXPermissions.Class) -> NSTextField {
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

    private func accessCheckbox(
        _ cls: POSIXPermissions.Class,
        _ access: POSIXPermissions.Access
    ) -> NSButton {
        let title: String
        switch access {
        case .read:
            title = String(localized: "Read", comment: "Mode bit: permission to read.")
        case .write:
            title = String(localized: "Write", comment: "Mode bit: permission to write.")
        case .execute:
            title = String(
                localized: "Execute",
                comment: "Mode bit: permission to run a file, or to traverse a folder."
            )
        }
        let box = editableCheckbox(title: title, isOn: snapshot.attributes.permissions[cls, access])
        modeBoxes.append(ModeCheckbox(box: box, cls: cls, access: access))
        return box
    }

    /// The `Mode:` row, whose value field is retained so ``refreshModeEcho`` can update it live.
    private func makeModeRow() -> NSView {
        let field = AttributeRow.valueField(
            AttributeFormatting.modeDescription(snapshot.attributes.permissions), monospaced: true
        )
        modeValueField = field
        return AttributeRow.make(
            label: String(
                localized: "Mode:",
                comment: "Info panel field label: the mode as ls and chmod spell it."
            ),
            field: field
        )
    }

    // MARK: - Special bits

    /// Set-UID / Set-GID / Sticky as a row of checkboxes — the other three of the twelve mode bits,
    /// which the read-only grid hid in a text line. Editable for the owner; a `chown` would clear
    /// set-uid/gid, but owner editing is a later pass, so nothing here re-orders around it yet.
    private func makeSpecialBitsRow() -> NSView {
        let permissions = snapshot.attributes.permissions
        let setUID = editableCheckbox(
            title: String(
                localized: "Set-UID", comment: "Mode special bit 4000, as a checkbox label."
            ),
            isOn: permissions.setUserID
        )
        setUserIDBox = setUID
        let setGID = editableCheckbox(
            title: String(
                localized: "Set-GID", comment: "Mode special bit 2000, as a checkbox label."
            ),
            isOn: permissions.setGroupID
        )
        setGroupIDBox = setGID
        let sticky = editableCheckbox(
            title: String(
                localized: "Sticky", comment: "Mode special bit 1000, as a checkbox label."
            ),
            isOn: permissions.sticky
        )
        stickyBox = sticky

        let row = NSStackView(views: [setUID, setGID, sticky])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 20
        return row
    }

    // MARK: - Flags

    private func makeFlagsColumn() -> NSView {
        let boxes: [NSView] = AttributeFormatting.editableFlags.map { flag, title in
            let box = editableCheckbox(title: title, isOn: snapshot.attributes.flags.contains(flag))
            flagBoxes.append((box, flag))
            return box
        }
        let column = NSStackView(views: boxes)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    // MARK: - Shared

    /// A checkbox that drives the working copy when the item is editable, and is a plain disabled
    /// indicator when it is not — one place so every editable box is wired the same way.
    private func editableCheckbox(title: String, isOn: Bool) -> NSButton {
        let box = NSButton(
            checkboxWithTitle: title,
            target: canEdit ? self : nil,
            action: canEdit ? #selector(editChanged(_:)) : nil
        )
        box.state = isOn ? .on : .off
        box.isEnabled = canEdit
        return box
    }
}
