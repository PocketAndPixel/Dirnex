import AppKit

/// The user's colours (PLAN.md §M15 Slice 2). App-wide like row density and show-hidden rather than
/// per tab — it is a matter of taste, not a question you ask of one directory — so the pane only
/// observes the shared value and re-renders; `AppPreferences` is the one place that writes it.
///
/// Shaped as the twin of `PanelViewController+Density`, deliberately, so there is one pattern for
/// "an app-wide View preference a pane must follow" rather than a new one per preference.
extension PanelViewController {
    /// Subscribe to `paletteDidChange` so this pane restyles live. Called once from `viewDidLoad`;
    /// the observer is torn down by the blanket `removeObserver(self)` in `deinit`.
    func observePalettePreference() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(palettePreferenceChanged),
            name: AppPreferences.paletteDidChange,
            object: nil
        )
    }

    @objc private func palettePreferenceChanged() {
        applyPalette()
    }

    /// Restyle the pane's three accented surfaces and repaint the rows.
    ///
    /// The path bar and the tab strip are told explicitly because neither is redrawn by a table
    /// refresh: each styles itself once, when its own state changes, and the accent it resolves is
    /// not part of that state. They are restyled *before* the rename guard, and unconditionally —
    /// they hold no field editor to protect, so an open inline rename must not leave the window half
    /// recoloured until the user presses Return.
    ///
    /// The rows themselves go through `renderRefresh` rather than `reloadEverything`, for the reason
    /// the density observer gives: nothing *moved*, so the cursor is re-applied without scrolling
    /// and the row the user was reading stays where it is. It also carries the `syncCursorToTable`
    /// tail that a bare `reloadData` drops, which NOTES.md records as a bug found live three times.
    func applyPalette() {
        pathBar.restyleForPalette()
        tabBar.restyleForPalette()
        if deferRefreshIfRenaming() { return }
        renderRefresh()
    }
}
