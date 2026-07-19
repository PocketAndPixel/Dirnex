import AppKit
import DirnexCore

/// Records a successful navigation into the two places that remember where the pane has
/// been: the active tab's back/forward trail (`NavigationHistory`, session-scoped) and the
/// app-wide frecency index (`FrecencyStore`, persistent, cross-window). Factored out of
/// `PanelViewController.navigate` so that file stays at its line budget (PLAN.md §M3).
extension PanelViewController {
    /// Record that `tab` just landed on `path`. Frecency records every visit — a jump via
    /// the back button is still a visit — while the back/forward trail is only appended for
    /// a *fresh* navigation (`recordHistory`), so walking the trail doesn't rewrite it.
    func recordVisit(_ path: VFSPath, tab: Int, recordHistory: Bool) {
        if recordHistory { tabs[tab].history.visit(path) }
        FrecencyStore.shared.recordVisit(path)
    }
}
