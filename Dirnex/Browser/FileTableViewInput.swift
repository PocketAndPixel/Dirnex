import AppKit
import DirnexCore

/// Keyboard commands a file pane's table forwards to its controller. Kept as an
/// explicit protocol (rather than target/action) so the Total Commander key model —
/// where Space marks and the cursor is separate from selection — stays readable and
/// testable, and so it can be regenerated from the action registry in M3.
@MainActor
protocol FileTableViewInput: AnyObject {
    /// Return / Enter / Cmd+Down — open the directory under the cursor or launch the file.
    func fileTableOpenSelection(_ tableView: FileTableView)
    /// Cmd+Return / Cmd+Enter — open the folder or archive under the cursor in a new tab of the
    /// other pane.
    func fileTableOpenSelectionInOtherPane(_ tableView: FileTableView)
    /// The second click of a Cmd-double-click on `row` — what Cmd+Return does, for the row clicked.
    /// The first click has already toggled that row's mark as any Cmd-click does.
    func fileTable(_ tableView: FileTableView, didCommandDoubleClickRow row: Int)
    /// Cmd+Up — navigate to the parent directory (unconditional, ignores any filter).
    func fileTableGoToParent(_ tableView: FileTableView)
    /// Backspace — trim the active type-to-filter, or go to the parent when it is empty.
    func fileTableBackspace(_ tableView: FileTableView)
    /// Esc — clear the filter, then (if none) clear the marks.
    func fileTableCancel(_ tableView: FileTableView)
    /// A printable character was typed — append it to the type-to-filter.
    func fileTable(_ tableView: FileTableView, didType text: String)
    /// Space / Insert — toggle the cursor row's mark and advance (TC's mark-a-run gesture).
    func fileTableToggleMarkAndAdvance(_ tableView: FileTableView)
    /// Tab — hand keyboard focus to the other pane.
    func fileTableSwitchPanel(_ tableView: FileTableView)
    /// Cmd+A — mark every visible entry.
    func fileTableMarkAll(_ tableView: FileTableView)
    /// `*` — invert the mark set.
    func fileTableInvertMarks(_ tableView: FileTableView)
    /// Keypad `+` — add entries matching a wildcard to the marks (TC's "select group").
    func fileTableSelectByPattern(_ tableView: FileTableView)
    /// Keypad `-` — remove entries matching a wildcard from the marks (TC's "unselect group").
    func fileTableDeselectByPattern(_ tableView: FileTableView)
    /// Cmd+Y — toggle the Quick Look preview panel.
    func fileTableToggleQuickLook(_ tableView: FileTableView)
    /// An arrow key — step the cursor one file while a full-size Quick View covers the list
    /// (PLAN.md §M11). Returns `true` when the arrows belong to Quick View, whether or not the
    /// cursor could move: at the ends of the list they stop rather than falling through to the
    /// table, and they never reach `..`.
    func fileTable(_ tableView: FileTableView, stepQuickViewCursorBy delta: Int) -> Bool
    /// ⇧ with an arrow, Page Up/Down or Home/End — scroll the Quick View preview on screen, at any of
    /// its three sizes. Returns `true` when a preview is up, whether or not it could scroll, so the key
    /// never also moves the cursor; `false` with none, and the key does what it always did.
    func fileTable(_ tableView: FileTableView, scrollQuickView move: QuickViewScroll) -> Bool

    /// → in tree mode (PLAN.md §M15 Slice 4) — expand the closed folder under the cursor, or step
    /// into an open one. Returns `false` in list mode, so the arrow falls through to the table
    /// unchanged there.
    func fileTableExpandOrStepIn(_ tableView: FileTableView) -> Bool
    /// ← in tree mode — collapse the open folder under the cursor, or step out to its parent's row.
    /// Returns `false` in list mode.
    func fileTableCollapseOrStepOut(_ tableView: FileTableView) -> Bool

    /// The lowest row the cursor may land on. `..` is off limits while a full-size Quick View
    /// covers the list — it is not a file to preview, so Home and Page Up stop at the first real
    /// row instead of parking on it and showing an empty surface.
    func fileTableMinimumCursorRow(_ tableView: FileTableView) -> Int
    /// A bare function key (F1–F12) reached the table unclaimed by a menu key-equivalent — the
    /// function bar dispatches its slot's command, if any. Returns `true` when a slot handled it.
    func fileTable(_ tableView: FileTableView, functionKey number: Int) -> Bool
    /// Cmd+L — edit the location as text in the path bar.
    func fileTableEditPath(_ tableView: FileTableView)
    /// Cmd+Shift+N (also File ▸ New Folder / F7) — create a folder here.
    func fileTableNewFolder(_ tableView: FileTableView)
    /// Cmd+Delete (also File ▸ Move to Trash / F8) — move the selection to the Trash.
    func fileTableDeleteToTrash(_ tableView: FileTableView)
    /// Cmd+Shift+Delete (also Delete Immediately / Shift+F8) — delete permanently.
    func fileTableDeletePermanently(_ tableView: FileTableView)
    /// The table became first responder — its pane should become the active one.
    func fileTableDidBecomeFirstResponder(_ tableView: FileTableView)
    /// A right-click (or Ctrl-click) landed on `row`, or `-1` in the empty space below the rows —
    /// the pane's context menu for it.
    func fileTable(_ tableView: FileTableView, menuForRow row: Int) -> NSMenu?
    /// A mouse button went down on `row` (or `-1` in empty space) with `modifiers`
    /// held — the Finder-style click selection (plain / Cmd-toggle / Shift-range).
    /// Returns `true` when the controller consumed it as a modifier selection and the
    /// table should skip its own click handling (no cursor move, no drag); `false` for a
    /// plain click, which the table still runs for cursor movement and drag-out.
    func fileTable(
        _ tableView: FileTableView,
        didClickRow row: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool
    /// A plain click on `row` was pressed on into a Force Click, the deeper second click of a Force
    /// Touch trackpad. It arrives once the button is up, after the click has put the cursor on `row`.
    func fileTable(_ tableView: FileTableView, didForceClickRow row: Int)
    /// The pointer moved onto `row`, or `-1` when it left the pane's rows. Only the tree's active
    /// indent guide reads it today; the cursor and the marks are deliberately untouched by hovering.
    func fileTable(_ tableView: FileTableView, didHoverRow row: Int)
    /// A drag is starting on `row`: the writers it carries in place of that row's own, or `nil` to
    /// drag the row alone. Asked before the drag session exists (`FileTableView+Drag`).
    func fileTable(
        _ tableView: FileTableView,
        dragWritersFromRow row: Int
    ) -> [any NSPasteboardWriting]?
}
