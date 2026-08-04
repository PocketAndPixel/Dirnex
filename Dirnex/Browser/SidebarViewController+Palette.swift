import AppKit

/// The sidebar's half of the user's colours (PLAN.md §M15 Slice 2), shaped as the twin of
/// `PanelViewController+Palette` so there is one pattern for "an app-wide preference a view must
/// follow" rather than a new one per surface.
///
/// The cursor colour is the only one of the three that reaches here. The accent belongs to the path
/// bar and the tab strip, and the mark colour to a pane's marked rows — a sidebar row is a place,
/// never a file, so it has neither.
extension SidebarViewController {
    /// Every row, so the selected one can wear the cursor colour the panes already draw in.
    /// Supplied unconditionally, like the panes': `SidebarRowView` hands an untouched palette
    /// straight back to `super`, so there is never a pool of one kind of row view to reconcile with
    /// the other (see `PanelRowView` for the probe behind that).
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("sidebarRow")
        let view: SidebarRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? SidebarRowView {
            view = reused
        } else {
            view = SidebarRowView()
            view.identifier = identifier
        }
        view.cursorColor = AppPreferences.shared.palette.cursor
        return view
    }

    /// Subscribe to `paletteDidChange` so the sidebar recolours live. Called once from
    /// `viewDidLoad`; the observer is torn down by the blanket `removeObserver(self)` in `deinit`.
    func observePaletteChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(paletteChanged),
            name: AppPreferences.paletteDidChange,
            object: nil
        )
    }

    /// A full `rebuild` rather than a bare `reloadData`: it is the one path that puts the selection
    /// back on the row that carried it, by path, and a recolour must not move the highlight.
    @objc private func paletteChanged() {
        rebuild()
    }
}
