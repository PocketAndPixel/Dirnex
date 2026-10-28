import AppKit

/// The right-click menu from the keyboard: File ▸ Show Context Menu, the palette, a chord the user
/// binds, and a lone tap of ⌥ (`OptionTapMenu`).
///
/// It is the menu a right-click on the cursor row shows, with one difference: nothing is retargeted.
/// A right-click on an unmarked row collapses the marks onto that row, because the pointer chose it.
/// The keyboard chose nothing, so the menu acts on what F5 or F8 would: the marks if there are any,
/// and the cursor row otherwise (`selectionTargets`). With neither (the cursor on `..`, or an empty
/// folder) it is the folder's menu, as a right-click on `..` or below the rows gives.
extension PanelViewController {
    @objc func showContextMenu(_ sender: Any?) {
        popUpOverCursorRow(keyboardContextMenu())
    }

    /// The menu ``showContextMenu(_:)`` drops over the cursor row. Separate so a test can read it
    /// without a menu's event loop.
    func keyboardContextMenu() -> NSMenu {
        // The items dispatch through the responder chain, so the table has to hold the focus, as
        // it does for a right-click (`contextMenu(forRow:)`).
        focusTable()
        let onEntry = !selectionTargets().isEmpty
        return contextMenu(onEntry: onEntry, onParentRow: !onEntry && cursorOnParentRow)
    }
}
