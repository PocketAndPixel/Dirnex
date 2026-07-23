import AppKit
import DirnexCore

// Rendering half of the Synchronize Directories sheet (PLAN.md §M5): the diff `NSTableView`'s
// cells and the per-row right-click override menu. The controller in
// `SyncDirectoriesController.swift` owns the state, scan, and chrome; this file only turns a
// `Row` into views and lets the user flip one row's action against the global direction.

// MARK: - Diff table

extension SyncDirectoriesController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
}

extension SyncDirectoriesController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let data = self.row(at: row) else { return nil }
        switch column.identifier.rawValue {
        case "include": return includeCheckbox(
                included: data.included,
                action: data.action,
                row: row
            )
        case "name": return nameCell(for: data.entry)
        case "left": return detailCell(for: data.entry.left)
        case "action": return actionCell(for: data.action)
        case "right": return detailCell(for: data.entry.right)
        default: return nil
        }
    }

    private func includeCheckbox(included: Bool, action: SyncAction, row: Int) -> NSView {
        let button = NSButton(
            checkboxWithTitle: "",
            target: self,
            action: #selector(toggleInclude(_:))
        )
        button.tag = row
        button.state = included ? .on : .off
        button.isEnabled = isActionable(action)
        return button
    }

    private func nameCell(for entry: SyncEntry) -> NSView {
        let name = entry.isDirectory ? entry.relativePath + "/" : entry.relativePath
        let field = NSTextField(labelWithString: name)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = entry.relativePath
        return field
    }

    private func detailCell(for entry: FileEntry?) -> NSView {
        guard let entry else {
            let dash = NSTextField(labelWithString: "—")
            dash.textColor = .tertiaryLabelColor
            return dash
        }
        let size = entry.isDirectory
            ? String(localized: "folder", comment: "Sync diff table: size cell for a subfolder.")
            : FileFormatting.sizeString(for: entry)
        let field = NSTextField(
            labelWithString: size + " · " + FileFormatting.dateString(for: entry)
        )
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.toolTip = field.stringValue
        return field
    }

    private func actionCell(for action: SyncAction) -> NSView {
        let display = actionDisplay(action)
        let field = NSTextField(labelWithString: display.glyph)
        field.alignment = .center
        field.textColor = display.color
        field.toolTip = display.tip
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    /// Glyph, colour, and tooltip for an action's cell — an arrow toward the side that changes
    /// for a copy, a red ✕ for a delete (which side is clear from the populated detail column),
    /// and a warning for a conflict the run skips.
    private func actionDisplay(_ action: SyncAction) -> ActionStyle {
        switch action {
        case .copyToRight: return ActionStyle("→", .systemGreen, copyToTip(rightDir.lastComponent))
        case .copyToLeft: return ActionStyle("←", .systemGreen, copyToTip(leftDir.lastComponent))
        case .deleteRight: return ActionStyle("✕", .systemRed, deleteFromTip(rightDir.lastComponent))
        case .deleteLeft: return ActionStyle("✕", .systemRed, deleteFromTip(leftDir.lastComponent))
        case .conflict: return ActionStyle(
                "⚠",
                .systemOrange,
                String(
                    localized: "Conflict — left unchanged",
                    comment: "Sync action tooltip: both sides changed; the run skips this row."
                )
            )
        case .none: return ActionStyle(
                "=",
                .tertiaryLabelColor,
                String(localized: "Identical", comment: "Sync action tooltip: the two sides match.")
            )
        }
    }

    /// "Copy to <folder>" for both the action cell's tooltip and the override menu; %@ is a
    /// folder name (data), so one localized frame serves every side.
    private func copyToTip(_ folder: String) -> String {
        String(
            localized: "Copy to \(folder)",
            comment: "Sync action: copy the item into the named folder; %@ is a folder name."
        )
    }

    private func deleteFromTip(_ folder: String) -> String {
        String(
            localized: "Delete from \(folder)",
            comment: "Sync action: delete the item from the named folder; %@ is a folder name."
        )
    }
}

// MARK: - Per-row override menu

extension SyncDirectoriesController: NSMenuDelegate {
    /// Rebuild the contextual menu for the row under the cursor: one item per legal override
    /// (`DirectorySync.availableActions`), a check on the row's current action, and a disabled
    /// caption when a row has no safe override (a file-vs-folder clash).
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = tableView.clickedRow
        guard let data = row(at: clicked) else { return }

        // A both-sides pair of regular files can be opened in an external diff tool — the
        // "how do they differ?" companion to the byte comparison (PLAN.md §M5 Compare-by-content).
        if data.entry.left?.kind == .file, data.entry.right?.kind == .file {
            let compare = NSMenuItem(
                title: compareContentsTitle(),
                action: #selector(compareContents(_:)),
                keyEquivalent: ""
            )
            compare.target = self
            compare.tag = clicked
            menu.addItem(compare)
        }

        let actions = DirectorySync.availableActions(for: data.entry.status)
        guard !actions.isEmpty else {
            if menu.items.isEmpty {
                let item = NSMenuItem(
                    title: overrideUnavailableTitle(for: data.entry.status),
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
            return
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for action in actions {
            let item = NSMenuItem(
                title: menuTitle(for: action),
                action: #selector(setRowAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = clicked
            item.representedObject = action
            item.state = data.action == action ? .on : .off
            menu.addItem(item)
        }
    }

    private func menuTitle(for action: SyncAction) -> String {
        switch action {
        case .copyToRight: return copyToTip(rightDir.lastComponent)
        case .copyToLeft: return copyToTip(leftDir.lastComponent)
        case .deleteLeft: return deleteFromTip(leftDir.lastComponent)
        case .deleteRight: return deleteFromTip(rightDir.lastComponent)
        case .none, .conflict: return ""
        }
    }

    private func overrideUnavailableTitle(for status: SyncStatus) -> String {
        status == .typeMismatch
            ? String(
                localized: "One side is a folder — resolve manually",
                comment: "Sync override menu: a file-vs-folder clash has no safe automatic action."
            )
            : String(
                localized: "No actions available",
                comment: "Sync override menu: this row has no legal override."
            )
    }

    /// Name the external-diff item after the tool that would open (so the user knows what launches),
    /// or a neutral title when none is installed — the click then explains how to get one.
    private func compareContentsTitle() -> String {
        if let tool = ExternalDiffLauncher.preferredTool() {
            return String(
                localized: "Compare with \(tool.displayName)…",
                comment: "Sync override menu: open the two files in an external diff tool; %@ is the tool name."
            )
        }
        return String(
            localized: "Compare Contents…",
            comment: "Sync override menu: open the two files in an external diff tool (none configured)."
        )
    }
}

/// The rendered appearance of one row's action, in the diff table's action column.
private struct ActionStyle {
    let glyph: String
    let color: NSColor
    let tip: String

    init(_ glyph: String, _ color: NSColor, _ tip: String) {
        self.glyph = glyph
        self.color = color
        self.tip = tip
    }
}
