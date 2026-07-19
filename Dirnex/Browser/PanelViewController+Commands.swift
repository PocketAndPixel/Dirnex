import AppKit

/// Thin `@objc` responder-chain wrappers for the actions that were previously reachable only
/// through the table's key model (Quick Look, Go to Location, Go Up). Exposing them as
/// selectors lets the M3 command registry drive them from the menu bar and the Cmd+K palette
/// alongside every other command — the palette dispatches these exactly like a menu item.
extension PanelViewController {
    /// ⌘Y — toggle the Quick Look preview panel (same as the in-table gesture).
    @objc func toggleQuickLookPreview(_ sender: Any?) {
        fileTableToggleQuickLook(tableView)
    }

    /// ⌘L — edit the current location as text in the path bar.
    @objc func editLocation(_ sender: Any?) {
        fileTableEditPath(tableView)
    }

    /// ⌘↑ — walk up to the parent directory, landing on the folder we came from.
    @objc func goToParentDirectory(_ sender: Any?) {
        goToParent()
    }
}
