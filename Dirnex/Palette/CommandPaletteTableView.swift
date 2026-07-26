import AppKit

/// The ⌘K palette's result list, which never takes first responder.
///
/// The search field owns the keyboard for the whole life of the panel: `control(_:doCommandBy:)`
/// is the *only* handler for ⎋, ⏎ and ↑/↓, and it fires only while the field is first responder.
/// A stock `NSTableView` takes focus in `mouseDown:`, so one click on a row left the palette
/// completely keyboard-dead — typing went nowhere, ⏎ ran nothing, ⎋ did not close it — with no
/// error and no log line. The only tell was the selection turning blue: AppKit draws the *same*
/// selection unemphasized (grey) when the table lacks focus and emphasized (blue) when it has it,
/// so the colour change was the focus theft, not a second highlight.
///
/// Refusing first responder costs nothing the list needs. `mouseDown:` selects rows regardless,
/// so clicking still moves the highlight, and the selection now draws one grey appearance whether
/// the mouse or the arrow keys put it there.
final class CommandPaletteTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}
