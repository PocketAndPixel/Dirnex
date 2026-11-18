import AppKit

/// What a key pressed in the ⌘K palette's search field does (PLAN.md §M3, §M40 Slice 1).
///
/// The field keeps first responder, so its keys arrive as the field editor's editing commands, and
/// the palette reads them in `control(_:textView:doCommandBy:)`. One key cannot be told by its
/// command: **a field editor sends ⌘Return as `noop:`**, the selector it sends for any key it has no
/// binding for (docs/NOTES.md ▸ Key equivalents, key monitors and menus). So ⌘Return is read off the
/// event that caused the command, which is a parameter here so a test can hand one over.
enum PaletteKey: Equatable {
    case moveUp
    case moveDown
    /// Run the highlighted row. With `inNewTab`, a place opens in a new tab of the active pane, as a
    /// ⌘-click or ⌘Return on its sidebar row does; anything else runs as it does for Return.
    case run(inNewTab: Bool)
    case close

    /// The command a field editor sends for a key it has no binding for. Named by string, since
    /// `NSResponder` declares no `noop(_:)` for Swift to name.
    static let noop = NSSelectorFromString("noop:")

    /// The palette's answer to `selector`, sent for `event`, or `nil` for a command the field should
    /// handle itself.
    static func action(for selector: Selector, event: NSEvent?) -> PaletteKey? {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): .moveUp
        case #selector(NSResponder.moveDown(_:)): .moveDown
        case #selector(NSResponder.insertNewline(_:)): .run(inNewTab: isCommandReturn(event))
        case #selector(NSResponder.cancelOperation(_:)): .close
        case noop: isCommandReturn(event) ? .run(inNewTab: true) : nil
        default: nil
        }
    }

    /// ⌘Return, or ⌘ and keypad Enter, with no other modifier key held: the file list's own rule for
    /// the same chord (`FileTableView.handleCommandReturn`). Only the four modifier keys count,
    /// because keypad Enter carries the numeric-pad flag and Caps Lock a flag of its own whenever it
    /// is lit.
    static func isCommandReturn(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return held == .command && (event.keyCode == 36 || event.keyCode == 76)
    }

    /// Whether a click on a result row opens a place in a new tab: ⌘ held, as a ⌘-click on a sidebar
    /// row.
    static func isCommandClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
    }
}
