import AppKit
import DirnexCore

/// The compare window's keys (PLAN.md §M31 Slice 3).
///
/// **A local monitor, not menu items**, the way `TabShortcuts` takes ⌘-digits in a dialog: a monitor
/// sees the key ahead of the menu bar, and the menu bar would otherwise take ⌘F (Favorites) and ⌘G
/// (Places) as disabled items there, which swallow the chord (docs/NOTES.md ▸ Key equivalents). It
/// runs only while this window is key.
///
/// - ⌥⌘↓ / ⌥⌘↑: the next and the previous change. No command in any preset is bound to either.
/// - ⌥⌘→ / ⌥⌘←: copy the current change to the right or the left file (`+Copy`, PLAN.md §M33),
///   free in every preset as well. A window that takes no copies takes the keys and beeps.
/// - F4: open the file in the pane holding the keyboard in the user's editor (`+Edit`, PLAN.md §M33
///   Slice 5), as F4 does in a pane. A window that takes no copies takes the key and beeps.
/// - ⌘U: swap sides, after Total Commander's Ctrl+U, which swaps its two panels. No command is
///   bound to it by default.
/// - ⌘S: save every edited side (`+Save`, PLAN.md §M33 Slice 3). The main menu has no Save item
///   to take it, and no command is bound to it either.
/// - ⌘W: close the window, asking first about unsaved edits, as its close button does. The menu's
///   ⌘W is the browser's Close Tab, which is disabled here, so until Slice 3 the key did nothing.
/// - ⌘F, ⌘G, ⇧⌘G: find in the pane holding the keyboard, with the system's find bar.
/// - ⎋: close the find bar if it is open, else the window. A field editor's own ⎋ (the find bar's
///   field) is left to it.
///
/// Tab and ⇧Tab are the key view loop's, set up in `+Layout`: the left pane, the right pane, then
/// the toolbar's controls, whose options have no key of their own. F4 and Find act on the pane
/// holding the keyboard, and while the toolbar has it, on the pane that had it last.
extension CompareWindowController {
    func windowDidBecomeKey(_ notification: Notification) {
        installKeyMonitor()
    }

    func windowDidResignKey(_ notification: Notification) {
        removeKeyMonitor()
    }

    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
    }

    func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    /// What a key does in this window: `true` when it was taken.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let character = event.charactersIgnoringModifiers?.lowercased()
        switch (event.specialKey, modifiers) {
        case (.downArrow?, [.option, .command]):
            goToNextChange()
            return true
        case (.upArrow?, [.option, .command]):
            goToPreviousChange()
            return true
        case (.rightArrow?, [.option, .command]):
            copyCurrentChange(to: .right)
            return true
        case (.leftArrow?, [.option, .command]):
            copyCurrentChange(to: .left)
            return true
        case (.f4?, []):
            editFile(on: focusedPane === rightPane ? .right : .left)
            return true
        default:
            break
        }
        switch (character, modifiers) {
        case ("f", [.command]):
            find(.showFindInterface)
            return true
        case ("g", [.command]):
            find(.nextMatch)
            return true
        case ("g", [.command, .shift]):
            find(.previousMatch)
            return true
        case ("u", [.command]):
            swapSides()
            return true
        case ("s", [.command]):
            saveFromKey()
            return true
        case ("w", [.command]):
            window?.performClose(nil)
            return true
        default:
            break
        }
        guard event.keyCode == 53, modifiers.isEmpty else { return false }
        return escape()
    }

    /// The pane the keyboard is in, or was in last: the left one until the right one has had it.
    var focusedPane: ComparePaneView {
        rightPane.holdsKeyboard ? rightPane : leftPane
    }

    /// Mark the pane on `side` as the one the keyboard is in.
    func paneTookKeyboard(_ side: ComparisonPaneText.Side) {
        for (each, pane) in panes {
            pane.holdsKeyboard = each == side
        }
    }

    private func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        focusedPane.textView.performTextFinderAction(item)
    }

    private func escape() -> Bool {
        // The find bar's field is a field editor: its ⎋ ends the search, and is its own.
        if let responder = window?.firstResponder as? NSTextView, !(responder is CompareTextView) {
            return false
        }
        for pane in [leftPane, rightPane] where pane.scrollView.isFindBarVisible {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.hideFindInterface.rawValue
            pane.textView.performTextFinderAction(item)
            return true
        }
        window?.performClose(nil)
        return true
    }
}
