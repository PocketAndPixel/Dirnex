import AppKit
import DirnexCore

/// The pane's side of the function-key bar (PLAN.md §M6): the View toggle that shows or hides
/// it, and the key handler that turns a bare function-key press into its slot's command. The bar
/// view and its window placement live in `FunctionBarView` / `BrowserWindowController+FunctionBar`;
/// this is the responder-chain glue.
extension PanelViewController {
    /// View ▸ Show Function Key Bar. App-wide, like Show Tags — every window reflects it, via the
    /// preference's own notification rather than by reaching across to the other windows here.
    @objc func toggleFunctionBar(_ sender: Any?) {
        AppPreferences.shared.toggleShowFunctionBar()
    }

    /// A bare function key reached this pane's table unclaimed by a menu key-equivalent. Look it up
    /// in the function bar and run its command against this pane, exactly as the button (and the
    /// menu item) would — so F3 "View" opens Quick Look on the active pane even though Quick Look's
    /// own shortcut is ⌘Y. Returns `false` (the press falls through) when no slot claims the key.
    ///
    /// Only keys with *no* menu equivalent arrive here — AppKit dispatches an equivalent before
    /// `keyDown` — which is exactly the set `FunctionBar` lets a user script bind, so a script's
    /// key reaches this method and nothing else can shadow it.
    func fileTable(_ tableView: FileTableView, functionKey number: Int) -> Bool {
        let scripts = UserScriptStore.load()
        let slots = FunctionBar.slots(
            userScripts: scripts.scripts,
            bindings: KeyBindingStore.shared.bindings
        )
        guard let slot = FunctionBar.slot(forFunctionKey: number, in: slots) else { return false }
        // A user script has no AppKit selector to send; resolve it and run it here. This pane is
        // the first responder (the press came from its table), so it needs none of the focus
        // restoration `BrowserWindowController.runCommand(id:)` does for a click or an Apple event
        // — both paths converge on `runScript`, which is where the one behaviour lives.
        if let name = UserScript.name(fromCommandID: slot.commandID) {
            guard let script = scripts.script(named: name) else { return false }
            runScript(script)
            return true
        }
        guard let selector = CommandBinding.selector(for: slot.commandID) else { return false }
        return NSApp.sendAction(selector, to: nil, from: tableView)
    }
}
