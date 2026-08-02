import AppKit

/// Row density (PLAN.md §M15 Slice 1). Like show-hidden and unlike sort or filter, this is a single
/// app-wide value (`AppPreferences.rowDensity`) rather than a per-tab one — flipping it re-sizes
/// *every* pane and tab at once. The pane only observes the shared value and re-renders; the value
/// itself lives on `AppPreferences` so the Settings picker is the one place that writes it.
///
/// The twin of `PanelViewController+Hidden`, deliberately: same shape, same lifecycle, so there is
/// one pattern for "an app-wide View preference a pane must follow" rather than two.
extension PanelViewController {
    /// Subscribe to `rowDensityDidChange` so this pane re-sizes live. Called once from
    /// `viewDidLoad`; the observer is torn down by the blanket `removeObserver(self)` in `deinit`.
    func observeRowDensityPreference() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rowDensityPreferenceChanged),
            name: AppPreferences.rowDensityDidChange,
            object: nil
        )
    }

    @objc private func rowDensityPreferenceChanged() {
        applyRowDensity()
    }

    /// Push the app-wide density into the table and repaint.
    ///
    /// `rowHeight` is assigned unconditionally — it is re-derived from the preference, never
    /// accumulated — so it is correct even when the repaint below is deferred. The repaint takes
    /// the usual rename guard: a `reloadData` while the inline field editor is open tears it out of
    /// its cell and strands it on the `..` row (NOTES.md ▸ AppKit), and the owed refresh is
    /// replayed when editing ends.
    ///
    /// `renderRefresh` rather than `reloadEverything` because nothing *moved*: the cursor is
    /// re-applied without scrolling, so the row the user was reading stays where it is instead of
    /// jumping to the middle of the pane. It is also the pass that carries the
    /// `syncCursorToTable` tail a bare `reloadData` would drop, which NOTES.md records as a bug
    /// found live three separate times.
    func applyRowDensity() {
        tableView.rowHeight = AppPreferences.shared.rowDensity.rowHeight
        if deferRefreshIfRenaming() { return }
        renderRefresh()
    }
}
