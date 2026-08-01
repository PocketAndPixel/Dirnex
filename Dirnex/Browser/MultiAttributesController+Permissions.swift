import AppKit
import DirnexCore

/// The multi-selection Permissions tab: group, the twelve mode bits and the BSD flags, all tri-state
/// (PLAN.md §M14 Slice 4).
///
/// A checkbox reads the selection: on/off when every item agrees, the **mixed dash** when they
/// disagree. Only a box the user moves off its starting state is written — a mixed box left mixed
/// means "leave each item's own value", which is the bulk-edit promise made visible. The reads all
/// go through the tested ``AttributePatch``; this file only lays out the controls and records what
/// each one stands for.
///
/// The English labels and their comments are the *same* as the single-item Permissions tab on
/// purpose: `String(localized:)` keys by English text, so reusing the exact strings reuses the exact
/// translations rather than minting a second copy of "Read" in fourteen languages.
extension MultiAttributesController {
    func makePermissionsTab() -> NSView {
        var rows: [NSView] = []

        if !canEdit {
            rows.append(makeNotOwnerNote())
        }

        rows.append(contentsOf: [
            AttributeRow.make(
                label: String(
                    localized: "Group:",
                    comment: "Info panel field label: the owning group (st_gid)."
                ),
                view: makeGroupPicker()
            ),
            AttributeRow.separator(),
            AttributeRow.make(
                label: String(
                    localized: "Access:",
                    comment: "Info panel field label: the grid of read/write/execute mode bits."
                ),
                view: makePermissionGrid()
            ),
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

        if canEdit {
            rows.append(AttributeRow.note(String(
                localized: """
                A dash means the selected items disagree on that setting. Leave it to keep each \
                item’s own value; tick or clear it to set it on all of them.
                """,
                comment: "Info panel note explaining the tri-state (mixed) checkboxes."
            )))
        }

        if items.contains(where: \.hasAccessControlList) {
            rows.append(AttributeRow.note(
                String(
                    localized: """
                    Some of these items also have access-control lists, which aren’t shown here. \
                    Open an item on its own to see and edit its list.
                    """,
                    comment: "Info panel note when a multi-selection contains items that carry ACLs."
                ),
                isWarning: true
            ))
        }

        return AttributeRow.pane(rows, width: MultiAttributesController.contentWidth)
    }

    // MARK: - Group

    /// The group popup, offering **Leave unchanged** first and then only the groups the caller can
    /// assign to any file — their own memberships. A per-item current group is deliberately *not*
    /// added the way the single-item picker adds one: there is no single current group across a
    /// selection, and offering a group the caller is not in would only produce an `EPERM` on the
    /// items not already in it.
    private func makeGroupPicker() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: String(
            localized: "Leave unchanged",
            comment: "First item of a multi-selection group popup: do not change any item's group."
        ))
        popup.lastItem?.tag = Self.leaveGroupUnchanged

        let member = actor.groupIDs.min() ?? 0
        let groups = IdentityRoster.selectableGroups(
            from: IdentityDirectory.groups(), memberOf: actor.groupIDs, current: member
        )
        for group in groups {
            popup.addItem(withTitle: AttributesSnapshot.describe(group.name, id: group.numericID))
            popup.lastItem?.tag = Int(group.numericID)
        }
        popup.selectItem(withTag: Self.leaveGroupUnchanged)
        popup.isEnabled = canEdit && !groups.isEmpty
        popup.target = self
        popup.action = #selector(editChanged(_:))
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        groupPopup = popup
        return popup
    }

    // MARK: - The mode grid

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
        let initial = tristate { $0.permissions[cls, access] }
        let box = makeTriCheckbox(title: title, initial: initial)
        modeBoxes.append(ModeTri(box: box, cls: cls, access: access, initial: initial))
        return box
    }

    // MARK: - Special bits

    private func makeSpecialBitsRow() -> NSView {
        let boxes = [
            specialCheckbox(.setUserID, title: String(
                localized: "Set-UID", comment: "Mode special bit 4000, as a checkbox label."
            ), predicate: \.setUserID),
            specialCheckbox(.setGroupID, title: String(
                localized: "Set-GID", comment: "Mode special bit 2000, as a checkbox label."
            ), predicate: \.setGroupID),
            specialCheckbox(.sticky, title: String(
                localized: "Sticky", comment: "Mode special bit 1000, as a checkbox label."
            ), predicate: \.sticky)
        ]
        let row = NSStackView(views: boxes)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 20
        return row
    }

    private func specialCheckbox(
        _ kind: SpecialKind,
        title: String,
        predicate: KeyPath<POSIXPermissions, Bool>
    ) -> NSButton {
        let initial = tristate { $0.permissions[keyPath: predicate] }
        let box = makeTriCheckbox(title: title, initial: initial)
        specialBoxes.append(SpecialTri(box: box, kind: kind, initial: initial))
        return box
    }

    // MARK: - Flags

    private func makeFlagsColumn() -> NSView {
        let boxes: [NSView] = AttributeFormatting.editableFlags.map { flag, title in
            let initial = tristate { $0.flags.contains(flag) }
            let box = makeTriCheckbox(title: title, initial: initial)
            flagBoxes.append(FlagTri(box: box, flag: flag, initial: initial))
            return box
        }
        let column = NSStackView(views: boxes)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }

    // MARK: - Tri-state shared

    /// The starting state of a checkbox for one predicate across the selection: on/off when every
    /// item agrees, mixed when they do not.
    private func tristate(_ predicate: (FileAttributes) -> Bool) -> NSControl.StateValue {
        var sawTrue = false
        var sawFalse = false
        for item in items {
            if predicate(item.attributes) { sawTrue = true } else { sawFalse = true }
            if sawTrue, sawFalse { return .mixed }
        }
        return sawTrue ? .on : .off
    }

    /// A tri-state checkbox, live for the owner. `allowsMixedState` is on only when the box *starts*
    /// mixed, so a bit the items agree on toggles cleanly on↔off while a bit they disagree on can be
    /// cycled through mixed → off → on and back to mixed (leave alone).
    private func makeTriCheckbox(title: String, initial: NSControl.StateValue) -> NSButton {
        let box = NSButton(
            checkboxWithTitle: title,
            target: canEdit ? self : nil,
            action: canEdit ? #selector(editChanged(_:)) : nil
        )
        box.allowsMixedState = initial == .mixed
        box.state = initial
        box.isEnabled = canEdit
        return box
    }

    // MARK: - Edit and commit gating

    /// Any control changed: rebuild the patch and light Save only when it would actually write.
    @objc func editChanged(_ sender: Any?) {
        refreshSaveEnabled()
    }

    func refreshSaveEnabled() {
        saveButton?.isEnabled = canEdit && !buildPatch().isEmpty
    }

    /// Turn the live controls into the ``AttributePatch`` the commit applies. A control still on its
    /// starting state contributes nothing — a mixed box left mixed, a checkbox not toggled, a date
    /// not ticked — so a bulk edit writes only the bits and fields the user actually moved.
    func buildPatch() -> AttributePatch {
        var patch = AttributePatch()

        for mode in modeBoxes where mode.box.state != mode.initial {
            patch.permissionMask[mode.cls, mode.access] = true
            patch.permissionValues[mode.cls, mode.access] = mode.box.state == .on
        }

        for special in specialBoxes where special.box.state != special.initial {
            let on = special.box.state == .on
            switch special.kind {
            case .setUserID:
                patch.permissionMask.setUserID = true
                patch.permissionValues.setUserID = on
            case .setGroupID:
                patch.permissionMask.setGroupID = true
                patch.permissionValues.setGroupID = on
            case .sticky:
                patch.permissionMask.sticky = true
                patch.permissionValues.sticky = on
            }
        }

        for flag in flagBoxes where flag.box.state != flag.initial {
            if flag.box.state == .on {
                patch.flagsToSet.insert(flag.flag)
            } else if flag.box.state == .off {
                patch.flagsToClear.insert(flag.flag)
            }
        }

        if let tag = groupPopup?.selectedItem?.tag, tag != Self.leaveGroupUnchanged {
            patch.groupID = UInt32(tag)
        }

        for date in dateRows where date.enable.state == .on {
            switch date.kind {
            case .access: patch.accessDate = date.picker.dateValue
            case .modification: patch.modificationDate = date.picker.dateValue
            case .creation: patch.creationDate = date.picker.dateValue
            }
        }

        return patch
    }
}
