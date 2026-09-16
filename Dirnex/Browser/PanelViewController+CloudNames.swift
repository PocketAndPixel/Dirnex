import AppKit

/// Following a rename of a sidebar **Cloud** row (`CloudPlaceTitle`) while the pane stands in that
/// place or has a tab there.
///
/// Neither surface that names the place redraws on its own: the path bar rebuilds only when the path
/// moves, and a tab chip's title is read only when the strip is rebuilt. The rows are untouched — no
/// file is named after a Cloud row — so the table is left alone.
extension PanelViewController {
    /// Subscribe to renames made in the app's own domain. Called once from `viewDidLoad`; torn down
    /// by the blanket `removeObserver(self)` in `deinit`.
    ///
    /// Scoped to `UserDefaults.standard`, so a test saving into a scratch domain does not redraw
    /// every live pane in the test host (docs/NOTES.md ▸ Testing).
    func observeCloudPlaceNames() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(cloudPlaceNamesChanged),
            name: CloudPlaceNameStore.didChangeNotification,
            object: UserDefaults.standard
        )
    }

    @objc private func cloudPlaceNamesChanged() {
        pathBar.reloadLocation()
        refreshTabBar()
    }
}
