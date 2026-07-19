import AppKit
import DirnexCore

/// Show/hide hidden (dot) files. Unlike sort or filter, this is a single app-wide toggle
/// (`AppPreferences.showHidden`), not a per-tab one — flipping it re-filters *every* pane and
/// tab at once (PLAN.md §M3 "Settings ▸ Panels"). The pane only observes the shared value and
/// re-renders; the toggle itself lives on `AppPreferences` so the header button, the ⇧⌘.
/// command, and the Settings toggle all funnel through the same state.
extension PanelViewController {
    /// Subscribe to `showHiddenDidChange` so this pane re-filters live when any surface flips
    /// the app-wide toggle. Called once from `viewDidLoad`; the observer is torn down by the
    /// blanket `removeObserver(self)` in `deinit`.
    func observeShowHiddenPreference() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showHiddenPreferenceChanged),
            name: AppPreferences.showHiddenDidChange,
            object: nil
        )
    }

    /// ⇧⌘. / View ▸ Show Hidden Files / the header eye button — flip the one app-wide value.
    /// The actual re-filter happens in every pane via the notification, including this one, so
    /// the two panes and all their tabs stay in lockstep.
    @objc func toggleShowHidden(_ sender: Any?) {
        AppPreferences.shared.toggleShowHidden()
    }

    @objc private func showHiddenPreferenceChanged() {
        applyGlobalShowHidden()
    }

    /// Push the app-wide value into every tab's model and re-render the active one. A no-op when
    /// the tabs already match, so an unrelated pref post can't churn the view. Uses the live
    /// refresh path (cursor preserved by identity, scroll left where it was) since toggling
    /// hidden files is closer to a background re-list than a navigation.
    private func applyGlobalShowHidden() {
        let show = AppPreferences.shared.showHidden
        guard tabs.contains(where: { $0.panel.model.showHidden != show }) else { return }
        for index in tabs.indices {
            tabs[index].panel.setShowHidden(show)
        }
        renderRefresh()
    }
}
