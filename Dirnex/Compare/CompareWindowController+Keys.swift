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
/// - ⌘F, ⌘G, ⇧⌘G: find in the pane holding the keyboard, with the system's find bar.
/// - ⎋: close the find bar if it is open, else the window. A field editor's own ⎋ (the find bar's
///   field) is left to it.
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
        default:
            break
        }
        guard event.keyCode == 53, modifiers.isEmpty else { return false }
        return escape()
    }

    /// The pane the keyboard is in, the left one when neither is.
    var focusedPane: ComparePaneView {
        window?.firstResponder === rightPane.textView ? rightPane : leftPane
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
