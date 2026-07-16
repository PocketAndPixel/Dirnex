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
    /// in the function bar and dispatch its command down the responder chain, exactly as the
    /// button (and the menu item) would — so F3 "View" opens Quick Look on the active pane even
    /// though Quick Look's own shortcut is ⌘Y. Returns `false` (the press falls through) when no
    /// slot claims the key.
    func fileTable(_ tableView: FileTableView, functionKey number: Int) -> Bool {
        guard let slot = FunctionBar.slot(forFunctionKey: number),
              let selector = CommandBinding.selector(for: slot.commandID) else { return false }
        return NSApp.sendAction(selector, to: nil, from: tableView)
    }
}
