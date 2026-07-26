import AppKit
import DirnexCore

/// The pane's undo/redo surface: the two menu actions (⌘Z / ⇧⌘Z) and their validators. Both
/// actions just forward to the window, which owns the window-global journal (PLAN.md §M2
/// "Undo journal"); the pane is only here because the menu/key-equivalent lands on the focused
/// responder. Split out of `+FileOps` so each file stays under SwiftLint's length limits.
///
/// The selectors are the **standard** `undo:` / `redo:`, the same trick `copy:` / `paste:` /
/// `selectAll:` already use here — and the only way ⌘Z reaches a text field at all, since Cocoa
/// binds no key to undo and a field editor therefore sees ⌘Z only as a menu key equivalent
/// (docs/NOTES.md). Unlike those three, though, `NSTextView` does *not* implement `undo:`:
/// measured, the responder chain walks straight past the field editor to `NSWindow`, which owns
/// the text undo. So a pane implementing `undo:` shadows the window in *both* cases and has to
/// hand the text case back itself — stepping aside is not available the way it is for ⌘C.
extension PanelViewController {
    /// ⌘Z — reverse the last operation on the window's undo journal, or undo typing when a text
    /// field is being edited (an inline rename, the path bar, a dialog's field).
    @objc func undo(_ sender: Any?) {
        if forwardToTextEditing(#selector(undo(_:)), sender) { return }
        host?.undoLastOperation()
    }

    /// ⇧⌘Z — re-apply the most recently undone operation, or redo typing while a text field is
    /// being edited. The ⌘Z twin in every respect.
    @objc func redo(_ sender: Any?) {
        if forwardToTextEditing(#selector(redo(_:)), sender) { return }
        host?.redoLastOperation()
    }

    /// Hand `selector` to the window when a field editor holds focus, and report having done so.
    ///
    /// It must go to the *window* rather than to the field editor or to an undo manager we pick:
    /// the field editor's undo manager is provably not the window's (`window.undoManager.canUndo`
    /// reads `false` while the editor's reads `true`), and driving that manager directly undid
    /// nothing. `NSWindow`'s own `undo:` is what resolves the right one — it is exactly the
    /// implementation this pane is standing in front of.
    private func forwardToTextEditing(_ selector: Selector, _ sender: Any?) -> Bool {
        guard let window = view.window, window.firstResponder is NSText else { return false }
        NSApp.sendAction(selector, to: window, from: sender)
        return true
    }

    /// Enable ⌘Z when there is something to reverse, and title the item after it ("Undo Move"),
    /// collapsing to plain "Undo" when idle. Called from `validateMenuItem` in `+MenuValidation`,
    /// so it can't be `private`.
    ///
    /// While a field editor is up the item *is* the text undo, so it reports that editor's state
    /// and takes AppKit's own title for it ("Undo Typing"), which is already localized in the
    /// language the app is pinned to. Disabling it here — what this used to do, on the assumption
    /// that ⌘Z would then fall through to the text — measurably left the key doing nothing at all.
    func validateUndoItem(_ menuItem: NSMenuItem) -> Bool {
        if let editor = view.window?.firstResponder as? NSText {
            menuItem.title = editor.undoManager?.undoMenuItemTitle ?? plainUndoTitle
            return editor.undoManager?.canUndo ?? false
        }
        guard let label = host?.nextUndoLabel else {
            menuItem.title = plainUndoTitle
            return false
        }
        let action = LocalizedCatalog.title(for: label)
        menuItem.title = String(
            localized: "Undo \(action)",
            comment: "Edit-menu item naming the action to undo, e.g. \"Undo Move\"."
        )
        return true
    }

    /// The ⇧⌘Z twin of `validateUndoItem`: the redo stack's next action ("Redo Move"), the
    /// editor's redo state while a text field is being edited, and plain "Redo" when neither has
    /// anything pending.
    func validateRedoItem(_ menuItem: NSMenuItem) -> Bool {
        if let editor = view.window?.firstResponder as? NSText {
            menuItem.title = editor.undoManager?.redoMenuItemTitle ?? plainRedoTitle
            return editor.undoManager?.canRedo ?? false
        }
        guard let label = host?.nextRedoLabel else {
            menuItem.title = plainRedoTitle
            return false
        }
        let action = LocalizedCatalog.title(for: label)
        menuItem.title = String(
            localized: "Redo \(action)",
            comment: "Edit-menu item naming the action to redo, e.g. \"Redo Move\"."
        )
        return true
    }

    /// The bare verb, for when nothing names what would be undone. A computed property because
    /// `String(localized:comment:)` takes a `StaticString`, so the comment cannot be shared any
    /// other way (docs/NOTES.md).
    private var plainUndoTitle: String {
        String(localized: "Undo", comment: "Edit-menu item with nothing to undo.")
    }

    private var plainRedoTitle: String {
        String(localized: "Redo", comment: "Edit-menu item with nothing to redo.")
    }
}
