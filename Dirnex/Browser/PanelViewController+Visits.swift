import DirnexCore

/// Records a successful navigation into the two places that remember where the pane has
/// been: the active tab's back/forward trail (`NavigationHistory`, kept with the tab) and the
/// app-wide frecency index (`FrecencyStore`, persistent, cross-window), which is reached through
/// the host so a pane with no window records nothing there. Factored out of
/// `PanelViewController.navigate` so that file stays at its line budget (PLAN.md §M3).
extension PanelViewController {
    /// Record that `tab` just landed on `path`. Frecency records every visit — a jump via
    /// the back button is still a visit — while the back/forward trail is only appended for
    /// a *fresh* navigation (`recordHistory`), so walking the trail doesn't rewrite it. A walk's
    /// landing is what ends it: the trail's position moved at the press, and the entry on screen
    /// moves only now that the folder has listed.
    func recordVisit(_ path: VFSPath, tab: Int, recordHistory: Bool) {
        if recordHistory {
            tabs[tab].history.visit(path)
        } else {
            tabs[tab].history.land(on: path)
        }
        host?.recordFrecencyVisit(path)
    }
}
