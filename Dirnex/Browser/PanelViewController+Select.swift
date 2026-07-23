import AppKit
import DirnexCore

/// Pattern-based marking for a file pane — Total Commander's gray-`+` / gray-`-`
/// "select group" gesture (PLAN.md §M1 "`+`/`-` glob select"). The matching itself
/// lives in `DirnexCore` (`Panel.selectMatching`/`deselectMatching`, backed by
/// `Glob`/`fnmatch`); this extension is only the AppKit shell: the wildcard prompt,
/// the menu actions, and the re-render.
///
/// The gesture is bound to the numeric keypad's `+`/`-` (see `FileTableView`) so it
/// never competes with type-to-filter — a bare `-` is a common filename character and
/// must keep reaching the filter. Laptops without a keypad reach the same commands
/// through the Select menu; rebindable shortcuts arrive with the M3 action registry.
extension PanelViewController {
    // MARK: - FileTableViewInput (keypad +/-)

    func fileTableSelectByPattern(_ tableView: FileTableView) {
        promptForPatternSelection(deselect: false)
    }

    func fileTableDeselectByPattern(_ tableView: FileTableView) {
        promptForPatternSelection(deselect: true)
    }

    // MARK: - Menu actions (dispatched to the focused pane via the responder chain)

    @objc func invertSelectionFiles(_ sender: Any?) {
        invertMarks()
    }

    @objc func selectFilesByPattern(_ sender: Any?) {
        promptForPatternSelection(deselect: false)
    }

    @objc func unselectFilesByPattern(_ sender: Any?) {
        promptForPatternSelection(deselect: true)
    }

    // MARK: - Shared selection helpers

    /// Invert the mark set and re-render. Shared by the `*` key and the Select menu.
    func invertMarks() {
        let previousMarks = panel.selection
        panel.invertSelection()
        recordMarkChange(since: previousMarks, label: "Invert Selection")
        redrawAfterSelectionChange()
    }

    // MARK: - Pattern prompt

    /// Ask for a wildcard and add (`deselect == false`) or remove (`deselect == true`)
    /// every visible entry whose name matches it. The field is prefilled with the
    /// cursor file's extension (`*.jpg`) — TC's touch that turns "mark all the JPEGs"
    /// into one keystroke and Return.
    private func promptForPatternSelection(deselect: Bool) {
        let alert = NSAlert()
        alert.messageText = deselect
            ? String(
                localized: "Unselect Files",
                comment: "Title of the wildcard-pattern dialog when removing files from the selection."
            )
            : String(
                localized: "Select Files",
                comment: "Title of the wildcard-pattern dialog when adding files to the selection."
            )
        alert.informativeText = String(
            localized: "Enter a wildcard pattern (for example “*.jpg”).",
            comment: "Wildcard-selection dialog body."
        )
        alert.addButton(withTitle: deselect
            ? String(
                localized: "Unselect",
                comment: "Confirm button of the wildcard dialog when removing files from the selection."
            )
            : String(
                localized: "Select",
                comment: "Confirm button of the wildcard dialog when adding files to the selection."
            ))
        alert.addButton(withTitle: String(localized: "Cancel", comment: "Dismiss button."))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultSelectionPattern()
        field.placeholderString = "*"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let pattern = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !pattern.isEmpty else { return }
            self?.applyPatternSelection(pattern, deselect: deselect)
        }

        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: apply)
            field.selectText(nil)
        } else {
            apply(alert.runModal())
        }
    }

    /// The pattern the prompt opens on: the cursor file's extension when it has one,
    /// otherwise every-file `*`. Parked on the synthetic `..` row there is no cursor
    /// file, so fall back to `*`.
    private func defaultSelectionPattern() -> String {
        guard !cursorOnParentRow,
              let entry = panel.currentEntry,
              !entry.fileExtension.isEmpty else { return "*" }
        return "*.\(entry.fileExtension)"
    }

    private func applyPatternSelection(_ pattern: String, deselect: Bool) {
        let previousMarks = panel.selection
        if deselect {
            panel.deselectMatching(pattern)
        } else {
            panel.selectMatching(pattern)
        }
        recordMarkChange(since: previousMarks, label: deselect ? "Unselect Files" : "Select Files")
        redrawAfterSelectionChange()
    }

    /// Marks changed but the cursor and row set did not — repaint the rows (so the
    /// bold-red mark styling updates), refresh the status summary, and keep any live
    /// Quick Look preview in step with the new marked set.
    private func redrawAfterSelectionChange() {
        tableView.reloadData()
        updateChrome()
        refreshQuickLookIfVisible()
    }
}
