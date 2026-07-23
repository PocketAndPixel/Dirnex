import AppKit
import DirnexCore

/// The pane's undo/redo surface: the two menu actions (⌘Z / ⇧⌘Z) and their validators. Both
/// actions just forward to the window, which owns the window-global journal (PLAN.md §M2
/// "Undo journal"); the pane is only here because the menu/key-equivalent lands on the focused
/// responder. Split out of `+FileOps` so each file stays under SwiftLint's length limits.
extension PanelViewController {
    /// ⌘Z — reverse the last operation on the window's undo journal. Validation steps aside for
    /// an active inline-rename/path-bar field editor so text undo still works.
    @objc func undoLastOperation(_ sender: Any?) {
        host?.undoLastOperation()
    }

    /// ⇧⌘Z — re-apply the most recently undone operation. Like ⌘Z, it forwards to the window
    /// and steps aside for an active field editor so a text redo still works.
    @objc func redoLastOperation(_ sender: Any?) {
        host?.redoLastOperation()
    }

    /// Enable ⌘Z only when the journal has something to reverse *and* no text field is being
    /// edited — while an inline rename / path-bar field editor is first responder, a disabled
    /// item lets `performKeyEquivalent` fall through so ⌘Z undoes typing instead. The title
    /// tracks the next action ("Undo Move"), collapsing to plain "Undo" when idle. Called from
    /// `validateMenuItem` in `+FileOps`, so it can't be `private`.
    func validateUndoItem(_ menuItem: NSMenuItem) -> Bool {
        if view.window?.firstResponder is NSText {
            menuItem.title = String(
                localized: "Undo",
                comment: "Edit-menu item with nothing to undo."
            )
            return false
        }
        guard let label = host?.nextUndoLabel else {
            menuItem.title = String(
                localized: "Undo",
                comment: "Edit-menu item with nothing to undo."
            )
            return false
        }
        let action = LocalizedCatalog.title(for: label)
        menuItem.title = String(
            localized: "Undo \(action)",
            comment: "Edit-menu item naming the action to undo, e.g. \"Undo Move\"."
        )
        return true
    }

    /// The ⇧⌘Z twin of `validateUndoItem`: enabled only when the redo stack has something *and*
    /// no text field is being edited (so ⇧⌘Z redoes typing there instead). The title tracks the
    /// next action ("Redo Move"), collapsing to plain "Redo".
    func validateRedoItem(_ menuItem: NSMenuItem) -> Bool {
        if view.window?.firstResponder is NSText {
            menuItem.title = String(
                localized: "Redo",
                comment: "Edit-menu item with nothing to redo."
            )
            return false
        }
        guard let label = host?.nextRedoLabel else {
            menuItem.title = String(
                localized: "Redo",
                comment: "Edit-menu item with nothing to redo."
            )
            return false
        }
        let action = LocalizedCatalog.title(for: label)
        menuItem.title = String(
            localized: "Redo \(action)",
            comment: "Edit-menu item naming the action to redo, e.g. \"Redo Move\"."
        )
        return true
    }
}
