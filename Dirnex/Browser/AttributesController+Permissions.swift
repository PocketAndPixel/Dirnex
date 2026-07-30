import AppKit
import DirnexCore

/// The Permissions tab: owner, group, the twelve mode bits and the BSD file flags
/// (PLAN.md §M14 Slice 4).
///
/// **The ACL note here is an M14 exit criterion, not decoration.** Adding an ACL does not change the
/// mode bits — probed: a file with an ACL still reads 0644 — so a panel that shows `rw-r--r--` and
/// says nothing else makes a *false* claim about the file's permissions on precisely the files where
/// the answer is not the mode. Whenever an ACL is present this tab says so and points at the tab
/// that lists it.
extension AttributesController {
    func makePermissionsTab() -> NSView {
        var rows: [NSView] = [
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
                value: snapshot.groupDescription
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
                    localized: "Mode:",
                    comment: "Info panel field label: the mode as ls and chmod spell it."
                ),
                value: modeDescription(),
                monospaced: true
            )
        ]

        if let special = specialBitsDescription() {
            rows.append(AttributeRow.make(
                label: String(
                    localized: "Special:",
                    comment: "Info panel field label: set-uid, set-gid and the sticky bit."
                ),
                value: special
            ))
        }

        rows.append(contentsOf: [
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

    // MARK: - The mode grid

    /// A read/write/execute column per class, as disabled checkboxes.
    ///
    /// Disabled rather than absent because this is the shape the editor becomes: the next pass makes
    /// the same grid live, so the layout is settled here where nothing can be misapplied yet.
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
        let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        box.state = snapshot.attributes.permissions[cls, access] ? .on : .off
        box.isEnabled = false
        return box
    }

    /// `rw-r--r--  (644)` — both spellings, because one is what `ls` shows and the other is what a
    /// user types at `chmod`.
    private func modeDescription() -> String {
        // Hoisted so the literal stays on one line and under the 120-column ceiling. The *literal*
        // has to remain single — a concatenation would extract nothing (docs/NOTES.md) — but the
        // values it interpolates need not be spelled out inside it.
        let symbolic = snapshot.attributes.permissions.symbolicString
        let octal = snapshot.attributes.permissions.octalString
        return String(
            localized: "\(symbolic)  (\(octal))",
            comment: "Info panel mode: %1$@ is the rwx string, %2$@ the octal digits."
        )
    }

    private func specialBitsDescription() -> String? {
        let permissions = snapshot.attributes.permissions
        var names: [String] = []
        if permissions.setUserID {
            names.append(String(
                localized: "set-user-ID",
                comment: "Mode special bit 4000, listed in a sentence."
            ))
        }
        if permissions.setGroupID {
            names.append(String(
                localized: "set-group-ID",
                comment: "Mode special bit 2000, listed in a sentence."
            ))
        }
        if permissions.sticky {
            names.append(String(
                localized: "sticky",
                comment: "Mode special bit 1000, listed in a sentence."
            ))
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    // MARK: - Flags

    private func makeFlagsColumn() -> NSView {
        let boxes: [NSView] = AttributeFormatting.editableFlags.map { flag, title in
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = snapshot.attributes.flags.contains(flag) ? .on : .off
            box.isEnabled = false
            return box
        }
        let column = NSStackView(views: boxes)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        return column
    }
}
