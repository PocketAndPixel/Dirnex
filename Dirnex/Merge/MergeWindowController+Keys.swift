import AppKit
import DirnexCore

/// The merge window's keys (PLAN.md §M34 Slice 3), taken by a local monitor while the window is
/// key, as the compare window's are (`CompareWindowController+Keys`, which says why not menu items).
///
/// - ⌥⌘↓ / ⌥⌘↑: the next and the previous conflict.
/// - ⌥⌘→ / ⌥⌘←: Take Yours and Take Theirs. The arrow points the way the lines go, from a side into
///   the result between them, as ⌥⌘→ copies to the right in the compare window.
/// - ⇧⌥⌘→ / ⇧⌥⌘←: take both sides, the arrow's side first.
/// - ⌥⌘B: Show Base. No command in any preset is bound to it.
/// - ⌘S: save the result, once every conflict has a choice. ⌘W: close, asking first about choices
///   not saved.
/// - ⌘F, ⌘G, ⇧⌘G: find in the pane holding the keyboard. ⎋: close the find bar, else the window.
extension MergeWindowController {
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
        switch (event.specialKey, modifiers) {
        case (.downArrow?, [.option, .command]):
            goToNextConflict()
        case (.upArrow?, [.option, .command]):
            goToPreviousConflict()
        case (.rightArrow?, [.option, .command]):
            take(.yours)
        case (.leftArrow?, [.option, .command]):
            take(.theirs)
        case (.rightArrow?, [.shift, .option, .command]):
            take(.yoursThenTheirs)
        case (.leftArrow?, [.shift, .option, .command]):
            take(.theirsThenYours)
        default:
            return handleCharacterKey(event, modifiers: modifiers)
        }
        return true
    }

    private func handleCharacterKey(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("b", [.option, .command]):
            setBaseShown(!isBaseShown)
        case ("f", [.command]):
            find(.showFindInterface)
        case ("g", [.command]):
            find(.nextMatch)
        case ("g", [.command, .shift]):
            find(.previousMatch)
        case ("s", [.command]):
            saveFromKey()
        case ("w", [.command]):
            window?.performClose(nil)
        default:
            guard event.keyCode == 53, modifiers.isEmpty else { return false }
            return escape()
        }
        return true
    }

    /// The pane the keyboard is in, the result when none is.
    var focusedPane: ComparePaneView {
        panes.first { window?.firstResponder === $0.pane.textView }?.pane ?? resultPane
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
        for (_, pane) in panes where pane.scrollView.isFindBarVisible {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.hideFindInterface.rawValue
            pane.textView.performTextFinderAction(item)
            return true
        }
        window?.performClose(nil)
        return true
    }
}
