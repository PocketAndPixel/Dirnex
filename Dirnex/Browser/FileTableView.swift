import AppKit

/// Keyboard commands a file pane's table forwards to its controller. Kept as an
/// explicit protocol (rather than target/action) so the Total Commander key model —
/// where Space marks and the cursor is separate from selection — stays readable and
/// testable, and so it can be regenerated from the action registry in M3.
@MainActor
protocol FileTableViewInput: AnyObject {
    /// Return / Enter / Cmd+Down — open the directory under the cursor or launch the file.
    func fileTableOpenSelection(_ tableView: FileTableView)
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
}

/// `NSTableView` subclass that intercepts the file-manager key model before the
/// default table behavior. Arrow keys and mouse selection fall through to `super`,
/// which moves the cursor (the table's own selection); everything else — navigation,
/// marking, and type-to-filter — is routed to the controller via `FileTableViewInput`.
final class FileTableView: NSTableView {
    weak var inputDelegate: FileTableViewInput?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let didBecome = super.becomeFirstResponder()
        if didBecome {
            inputDelegate?.fileTableDidBecomeFirstResponder(self)
        }
        return didBecome
    }

    /// The Escape key reaches AppKit as the `cancelOperation:` action rather than a
    /// plain `keyDown:` we can switch on, so we take it here — this clears the active
    /// type-to-filter (then the marks).
    override func cancelOperation(_ sender: Any?) {
        inputDelegate?.fileTableCancel(self)
    }

    /// Cmd+A — mark every visible entry. Routed through the standard `selectAll:` action
    /// (bound to Cmd+A by the "Select All" menu item) rather than `keyDown:` so that, while
    /// an inline rename field is being edited, the *field editor* wins the shortcut and
    /// selects all of the name (extension included) instead of this marking the whole pane.
    override func selectAll(_ sender: Any?) {
        inputDelegate?.fileTableMarkAll(self)
    }

    /// Keep the "Select All" menu item live even though the table is single-selection
    /// (`allowsMultipleSelection == false`), which would otherwise let `NSTableView` disable
    /// it — here `selectAll:` marks the whole pane rather than extending the row selection.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(selectAll(_:)) {
            return numberOfRows > 0
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Route clicks through the controller's Finder-style selection first. A Cmd/Shift
    /// click is consumed there (it drives the mark set, not the table's own single
    /// selection); a plain click leaves the marks alone and falls through to `super` so
    /// the cursor moves and a drag-out can begin.
    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        if inputDelegate?.fileTable(self, didClickRow: row, modifiers: flags) == true {
            return
        }
        // A plain click in the empty area below the last row would make `super` clear the
        // selection (the table allows empty selection), dropping the cursor highlight and — since
        // the file commands need a cursor/selection — effectively disabling F5/F6/F8. In a Total
        // Commander pane an empty-space click is a no-op, not a deselect: take (or keep) focus for
        // this pane but leave the cursor where it is. `super` is skipped so the selection stands.
        if row < 0 {
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    /// Right-click / Ctrl-click — hand the controller the row under the pointer and show what it
    /// builds. Overridden rather than setting a static `menu`, because the menu depends on *where*
    /// the click landed (a row, or the empty space below the list) and on what is marked, so it can
    /// only be assembled once the event is in hand.
    ///
    /// `NSTableView` does have `menu(for:)` on its own path, but its default also fiddles with the
    /// row selection to match the click; this pane has its own selection model (marks independent of
    /// the cursor), so the retargeting is the controller's to do.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return inputDelegate?.fileTable(self, menuForRow: row(at: point))
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == .command {
            if handleCommandArrow(event.keyCode) { return }
            if event.keyCode == 51 { // Cmd+Delete — move to Trash (Finder's shortcut)
                inputDelegate?.fileTableDeleteToTrash(self)
                return
            }
            switch event.charactersIgnoringModifiers {
            // Cmd+A (mark all) is handled via the `selectAll:` action so the rename field
            // editor can claim it while editing — see `selectAll(_:)` above.
            case "y": inputDelegate?.fileTableToggleQuickLook(self); return
            case "l": inputDelegate?.fileTableEditPath(self); return
            default: break
            }
        }

        if flags == [.command, .shift] {
            if event.keyCode == 51 { // Cmd+Shift+Delete — delete permanently
                inputDelegate?.fileTableDeletePermanently(self)
                return
            }
            if event.charactersIgnoringModifiers?.lowercased() == "n" { // Cmd+Shift+N — new folder
                inputDelegate?.fileTableNewFolder(self)
                return
            }
        }

        // A bare function key (F1–F12) the menu didn't already claim: hand it to the function bar.
        // F2/F5–F8 carry menu key-equivalents, so those fire via the menu and never arrive here;
        // only a function key *without* one (F3 View, a user script's binding) reaches this, so
        // there is no double-dispatch. The `fn` layer rides with every F-key, so allow it.
        if flags.subtracting([.function, .numericPad]).isEmpty,
           let number = Self.functionKeyNumber(for: event),
           inputDelegate?.fileTable(self, functionKey: number) == true {
            return
        }

        // Plain keys, plus Shift/keypad/function so uppercase typing and the arrow/
        // navigation cluster still route through here.
        let passthrough: NSEvent.ModifierFlags = [.shift, .numericPad, .function]
        if flags.subtracting(passthrough).isEmpty, handleTypingKey(event) { return }

        super.keyDown(with: event)
    }

    /// The number of the function key `event` represents (F5 → 5), or `nil` when it isn't one —
    /// AppKit reports F-keys as scalars in the contiguous `NSF1FunctionKey…NSF35FunctionKey` range.
    private static func functionKeyNumber(for event: NSEvent) -> Int? {
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let value = Int(scalar.value)
        guard value >= NSF1FunctionKey, value <= NSF35FunctionKey else { return nil }
        return value - NSF1FunctionKey + 1
    }

    /// Cmd + arrow: enter directory / go up, mirroring Finder's Cmd+Down / Cmd+Up.
    private func handleCommandArrow(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 125: // Down
            inputDelegate?.fileTableOpenSelection(self)
            return true
        case 126: // Up
            inputDelegate?.fileTableGoToParent(self)
            return true
        default:
            return false
        }
    }

    private func handleTypingKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 48: // Tab
            inputDelegate?.fileTableSwitchPanel(self)
            return true
        case 36, 76: // Return, keypad Enter
            inputDelegate?.fileTableOpenSelection(self)
            return true
        case 51: // Delete (Backspace)
            inputDelegate?.fileTableBackspace(self)
            return true
        case 115: // Home
            moveCursor(to: 0)
            return true
        case 119: // End
            moveCursor(to: numberOfRows - 1)
            return true
        case 116: // Page Up
            moveCursor(by: -visibleRowCount())
            return true
        case 121: // Page Down
            moveCursor(by: visibleRowCount())
            return true
        case 69: // Keypad + — select by wildcard (TC's gray-plus)
            inputDelegate?.fileTableSelectByPattern(self)
            return true
        case 78: // Keypad - — unselect by wildcard (TC's gray-minus)
            inputDelegate?.fileTableDeselectByPattern(self)
            return true
        default:
            break
        }

        switch event.charactersIgnoringModifiers {
        case " ":
            inputDelegate?.fileTableToggleMarkAndAdvance(self)
            return true
        case "*":
            inputDelegate?.fileTableInvertMarks(self)
            return true
        default:
            break
        }

        return forwardTypedCharacter(event)
    }

    /// Route a single printable character into the type-to-filter, excluding control
    /// characters and the 0xF700–0xF8FF function-key range (arrows, F-keys) that AppKit
    /// reports as "characters" but which must reach `super` for cursor movement.
    private func forwardTypedCharacter(_ event: NSEvent) -> Bool {
        guard let chars = event.characters,
              chars.count == 1,
              let scalar = chars.unicodeScalars.first,
              scalar.value > 0x20,
              scalar.value != 0x7F,
              !(0xF700...0xF8FF).contains(scalar.value) else {
            return false
        }
        inputDelegate?.fileTable(self, didType: chars)
        return true
    }

    // MARK: - Cursor movement

    private func moveCursor(by delta: Int) {
        moveCursor(to: selectedRow + delta)
    }

    private func moveCursor(to row: Int) {
        guard numberOfRows > 0 else { return }
        let clamped = min(max(row, 0), numberOfRows - 1)
        selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
        scrollRowToVisible(clamped)
    }

    private func visibleRowCount() -> Int {
        let rows = rows(in: visibleRect)
        return max(rows.length - 1, 1)
    }
}
