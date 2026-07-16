import AppKit
import DirnexCore

/// The window-level actions the AppleScript verbs drive (PLAN.md §M6 "Automation: AppleScript/
/// Shortcuts verbs"). The `NSScriptCommand` subclasses in `ScriptingCommands.swift` do the Apple
/// event decoding; this is where a decoded verb meets the active panel.
///
/// `runCommand(id:)` is the single dispatch path shared by the AppleScript `run operation`/`copy
/// selection` verbs *and* the function-key bar: it brings the active pane forward and then sends the
/// command's selector — or, for a `userScript.*` id, routes to the script runner exactly as the ⌘K
/// palette does. Centralizing it here means the bar, the palette, and AppleScript can never dispatch
/// a command three subtly different ways.
extension BrowserWindowController {
    /// Focus the active pane and run the catalog command (or user script) with `id`, returning
    /// whether anything was dispatched. `false` means `id` names neither a wired selector nor a
    /// saved user script — the caller (an AppleScript handler) turns that into a script error.
    @discardableResult
    func runCommand(id: String) -> Bool {
        bringPaneForward()
        if let name = UserScript.name(fromCommandID: id) {
            let sender = NSMenuItem()
            sender.representedObject = name
            return dispatch(#selector(PanelViewController.runUserScript(_:)), sender: sender)
        }
        guard let selector = CommandBinding.selector(for: id) else { return false }
        return dispatch(selector, sender: nil)
    }

    /// Bring Dirnex forward and reveal `target` in the active panel: navigate to the container and
    /// land the cursor on the item (Finder's reveal — the item is selected *in* its folder, not
    /// entered). Used by the AppleScript `reveal` verb.
    func reveal(_ target: AutomationRevealTarget) {
        bringPaneForward()
        focusedPanel.navigate(to: target.container, focus: target.item)
        focusedPanel.focusTable()
    }

    /// Dispatch `selector` starting from the active pane's first responder (its table), walking up
    /// the responder chain to the pane, window, and window controller.
    ///
    /// This deliberately uses `tryToPerform` rather than `NSApp.sendAction(_:to:nil:)`: an Apple
    /// event usually arrives while Dirnex is a *background* app, and `activate`/`makeKeyAndOrderFront`
    /// do not grant key-window status synchronously — so within this same call there is still no key
    /// window, and `sendAction(to: nil)` (which starts at the key window's first responder) would
    /// find no responder and silently no-op (the pass-14 nil-target trap, here because the whole app
    /// is inactive). Walking the pane's own chain doesn't depend on key status. The `sendAction`
    /// fallback covers the few app-level commands (Settings, Quit) that live above the window chain.
    private func dispatch(_ selector: Selector, sender: Any?) -> Bool {
        if let responder = window?.firstResponder, responder.tryToPerform(selector, with: sender) {
            return true
        }
        return NSApp.sendAction(selector, to: nil, from: sender)
    }

    /// Activate the app, make the window key, and focus the active pane, so the scripted command
    /// runs on a visible, focused window — a script usually invokes a verb while Dirnex is in the
    /// background. Harmless when the app is already frontmost — the function-key bar, which shares
    /// `runCommand`, just re-asserts the focus it already has.
    private func bringPaneForward() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        focusedPanel.focusTable()
    }
}
