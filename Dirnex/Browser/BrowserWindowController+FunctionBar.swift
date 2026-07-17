import AppKit
import DirnexCore

/// Show/hide wiring for the window-bottom function-key bar (PLAN.md §M6). The bar itself is
/// built in `makeContainerViewController`; here it tracks `AppPreferences.showFunctionBar`, which
/// the View menu item, the ⌘K palette command, and the Settings toggle all drive. App-wide, like
/// the tags column: every open window collapses or expands its bar together.
extension BrowserWindowController {
    /// Apply the saved preference to this window's bar, wire button clicks to the active pane, and
    /// subscribe to future preference changes. Called once from `init`, after the container (and so
    /// `functionBarHeight`) exists.
    func installFunctionBar() {
        functionBar.onRun = { [weak self] slot in self?.runFunctionBarSlot(slot) }
        reloadFunctionBarSlots()
        applyFunctionBarVisibility()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(functionBarStateChanged),
            name: AppPreferences.showFunctionBarDidChange,
            object: nil
        )
        // The bar's *contents* move too, not just its visibility: binding a script to F9 (or
        // renaming it), and rebinding a command onto a function key — which can reserve a key a
        // script was using — both change what the row should print.
        for name in [UserScriptStore.didChangeNotification, KeyBindingStore.didChange] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(functionBarSlotsChanged),
                name: name,
                object: nil
            )
        }
    }

    /// Rebuild the bar: the built-in slots plus every user script holding a key that is free under
    /// the user's current bindings. The same join the pane's key handler makes, so a button and its
    /// key can never disagree about what F9 does.
    func reloadFunctionBarSlots() {
        functionBar.setSlots(FunctionBar.slots(
            userScripts: UserScriptStore.load().scripts,
            bindings: KeyBindingStore.shared.bindings
        ))
    }

    @objc private func functionBarSlotsChanged() {
        reloadFunctionBarSlots()
    }

    /// Run a function-bar button's command against the active pane. A bottom-bar click lands
    /// outside both panes and drops the pane's first-responder status, so `runCommand(id:)`
    /// re-focuses the active pane — which also matches Total Commander, where a function-button
    /// click acts on the active pane and leaves focus there — then dispatches the command, exactly
    /// like the menu item and the AppleScript `run operation` verb, now that the pane is back in the
    /// responder chain.
    private func runFunctionBarSlot(_ slot: FunctionBarSlot) {
        runCommand(id: slot.commandID)
    }

    @objc private func functionBarStateChanged() {
        applyFunctionBarVisibility()
    }

    /// Collapse the bar to zero height (and hide it) when the feature is off, giving the panes the
    /// whole window; expand it to its fixed height when on. Hiding as well as collapsing keeps it
    /// out of the hit-testing and accessibility trees while off.
    private func applyFunctionBarVisibility() {
        let visible = AppPreferences.shared.showFunctionBar
        functionBar.isHidden = !visible
        functionBarHeight.constant = visible ? FunctionBarView.preferredHeight : 0
    }
}
