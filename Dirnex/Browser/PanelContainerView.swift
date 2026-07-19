import AppKit

/// A file pane's root view. Clicks that fall through the pane's chrome — the inset margins and
/// the spacing gaps around the tab strip, path bar, and status line — land here rather than on
/// the file table. Left alone, such a click moves the window's first responder off the
/// `FileTableView`; and because the file commands (F5/F6 copy/move, F7 New Folder, F8 Delete,
/// …) are dispatched through the responder chain with a *nil* target (see `MainMenuBuilder`),
/// they go dead the moment no pane is first responder. Redirecting an empty-space click back to
/// the table keeps this pane focused and active, matching Finder — click anywhere in a pane and
/// it takes focus.
final class PanelContainerView: NSView {
    /// The file table to hand focus back to. Weak — it is owned by the view hierarchy.
    weak var fileTable: NSView?

    override func mouseDown(with event: NSEvent) {
        if let fileTable, window?.firstResponder !== fileTable {
            window?.makeFirstResponder(fileTable)
        }
        // Deliberately not calling `super`: the click's only job here is to refocus the pane.
        // Forwarding it up the responder chain would just reach the window's content view.
    }
}
