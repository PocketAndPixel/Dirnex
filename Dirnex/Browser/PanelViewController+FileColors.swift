import AppKit
import DirnexCore

/// Colour rules by file type (PLAN.md §M15 Slice 3) — Total Commander's signature ordered
/// glob → colour list, resolved at the point of drawing.
///
/// App-wide like the palette and row density rather than per tab, and shaped as the twin of
/// `PanelViewController+Palette` so there is one pattern for "an app-wide View preference a pane must
/// follow" rather than a new one per preference. The core owns *which* rule claims a row
/// (`FileColorRules.firstMatch`); this owns the pixels — the split `FinderTag` already makes, where
/// the colour rides as data and the app maps it.
extension PanelViewController {
    /// Subscribe to `FileColorRuleStore.didChangeNotification` so this pane repaints live while the
    /// Settings editor is open. Called once from `viewDidLoad`; the observer is torn down by the
    /// blanket `removeObserver(self)` in `deinit`.
    func observeFileColorRules() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fileColorRulesChanged),
            name: FileColorRuleStore.didChangeNotification,
            object: nil
        )
    }

    @objc private func fileColorRulesChanged() {
        applyFileColorRules()
    }

    /// Repaint the rows for a changed rule list.
    ///
    /// `renderRefresh` rather than `reloadEverything`, for the reason the palette and density
    /// observers both give: nothing *moved*, so the cursor is re-applied without scrolling and the
    /// row the user was reading stays under their eye. It also carries the `syncCursorToTable` tail
    /// that a bare `reloadData` drops — the bug NOTES.md records as having been found live three
    /// times. Nothing outside the table draws a type colour, so unlike `applyPalette` there is no
    /// path bar or tab strip to restyle alongside it.
    func applyFileColorRules() {
        if deferRefreshIfRenaming() { return }
        renderRefresh()
    }

    /// The colour a rule gives `entry`, or `nil` when no rule claims it — the answer for every row
    /// on an untouched install, where the list is empty and the lookup is free.
    ///
    /// A rule whose stored hex is unusable draws **no colour** rather than a colour nobody chose:
    /// `PanelPalette.color(fromHex:)` is deliberately strict on the way in (a hand-edited or
    /// newer-build value returns `nil`), and the row simply falls through to `.labelColor` — the
    /// same degradation the three palette colours already make.
    func typeColor(for entry: FileEntry) -> NSColor? {
        guard let rule = FileColorRuleStore.rules.firstMatch(for: entry) else { return nil }
        return PanelPalette.color(fromHex: rule.colorHex)
    }
}
