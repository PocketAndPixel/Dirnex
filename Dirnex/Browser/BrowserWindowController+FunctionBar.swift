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
        applyFunctionBarVisibility()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(functionBarStateChanged),
            name: AppPreferences.showFunctionBarDidChange,
            object: nil
        )
    }

    /// Run a function-bar button's command against the active pane. A bottom-bar click lands
    /// outside both panes and drops the pane's first-responder status, so first re-focus the active
    /// pane — which also matches Total Commander, where a function-button click acts on the active
    /// pane and leaves focus there — then dispatch the command to nil, exactly like the menu item,
    /// now that the pane is back in the responder chain.
    private func runFunctionBarSlot(_ slot: FunctionBarSlot) {
        guard let selector = CommandBinding.selector(for: slot.commandID) else { return }
        focusedPanel.focusTable()
        NSApp.sendAction(selector, to: nil, from: nil)
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
