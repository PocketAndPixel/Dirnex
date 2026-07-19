import DirnexCore
import Foundation

/// One tab within a file pane: everything needed to restore its exact view when the
/// user switches back to it. A `PanelViewController` owns an array of these and renders
/// whichever is active (PLAN.md §M1 "tabs per panel … restored on relaunch").
///
/// The full pane state lives in the value-type `Panel` (directory, cursor, marks, sort,
/// filter) — so a tab is essentially a `Panel` plus the two bits of view state the
/// controller keeps outside it: whether the cursor sits on the synthetic `..` row, and
/// whether this tab's directory has been listed yet (an inactive restored tab loads
/// lazily the first time it becomes active).
@MainActor
final class PanelTab {
    var panel: Panel
    /// This tab's back/forward navigation trail (PLAN.md §M3 "Per-panel history"). Seeded at
    /// the tab's starting directory and grown as navigation records visits; session-scoped,
    /// so a relaunched tab starts a fresh trail at its restored path.
    var history: NavigationHistory
    /// The visible cursor is parked on the `..` row (UI-only; see `PanelViewController`).
    var cursorOnParentRow = false
    /// Set once this tab's directory has been listed. A tab restored from disk starts
    /// `false` so switching to it triggers a fresh load rather than showing an empty list.
    var hasLoaded = false
    /// This tab's column widths/order, in display order (UI-only, like `cursorOnParentRow`;
    /// see `PanelViewController+Columns`). `nil` until the tab has been given an explicit
    /// layout — restored from disk or inherited from the tab it was spawned from — in which
    /// case the pane falls back to the default columns.
    var columnLayout: [ColumnLayout]?
    /// When this tab shows Spotlight results (a `.search` panel), the query and scope that
    /// produced them — retained so "Save Search…" can persist a re-runnable saved search
    /// (PLAN.md §M4). `nil` for a normal directory tab. Session-scoped: a restored tab is never
    /// a results tab (search results aren't persisted), so this is never encoded.
    var searchQuery: SpotlightQuery?
    var searchScope: VFSPath?
    /// The Git working tree this tab's directory belongs to, and the snapshot its rows are painted
    /// from (PLAN.md §M6) — both `nil` outside a repository, and the snapshot also `nil` until the
    /// first `git status` lands. UI-only and session-scoped, like `cursorOnParentRow`: they are
    /// derived from the directory on switching to the tab, never persisted. Managed by
    /// `PanelViewController+Git`.
    var gitRepositoryRoot: VFSPath?
    var gitSnapshot: GitStatusSnapshot?
    /// The Finder tags this tab's rows are painted from (PLAN.md §M6), `nil` until the first scan
    /// lands. UI-only and session-scoped like the Git pair above: derived from the directory on
    /// switching to the tab, never persisted. Managed by `PanelViewController+Tags`.
    var tagSnapshot: FinderTagSnapshot?
    /// The cloud sync status this tab's rows are painted from (PLAN.md §M6), `nil` until the first
    /// scan lands — and empty, not `nil`, in the ordinary folder the scan skipped. UI-only and
    /// session-scoped like the pairs above. Managed by `PanelViewController+SyncStatus`.
    var syncSnapshot: CloudSyncSnapshot?
    /// Whether this tab shows ncdu-style size bars, and the projection they are drawn from (PLAN.md
    /// §M6). Per tab rather than app-wide because the mode *spends* something to be on — measured,
    /// ~16 s of background walking for one `~` — so it belongs to the tab you pointed at a tree, not
    /// to every tab at once. UI-only and session-scoped like the pairs above; the projection is
    /// rebuilt on every render pass, since both its denominators cover only the rows currently
    /// visible. Managed by `PanelViewController+SizeViz`.
    var isSizeVisualizationEnabled = false
    var sizeVisualization: SizeVisualization?
    /// Whether this tab's folder totals leave out what Git ignores (PLAN.md §M6, the optional slice
    /// of Git awareness). Per tab and session-scoped like the mode above, and for a stronger reason:
    /// it changes what a *number* means, so it must belong to the pane you set it on rather than
    /// silently reinterpreting the size column in every other tab. Managed by
    /// `PanelViewController+SizeViz`.
    var isGitAwareSizesEnabled = false
    /// An explicit chip label overriding the path-derived one — set when a search is saved (or a
    /// saved search is re-run) so a results tab reads as its friendly name ("JMeter search")
    /// rather than the raw query (`"jmeter"`). `nil` for an ordinary tab. Session-scoped like
    /// `searchQuery` (search tabs aren't persisted).
    var customTitle: String?

    init(panel: Panel) {
        self.panel = panel
        history = NavigationHistory(initialPath: panel.path)
    }

    /// A new tab rooted at `path`, inheriting the sort/hidden settings — and, when given,
    /// the column layout — of the tab it was spawned from so a fresh tab matches the pane
    /// you opened it from.
    convenience init(
        path: VFSPath,
        sort: FileSort = .default,
        showHidden: Bool = false,
        columns: [ColumnLayout]? = nil
    ) {
        self.init(panel: Panel(path: path, sort: sort, showHidden: showHidden))
        columnLayout = columns
    }

    /// The short label shown on the tab chip — a saved search's custom name when set, else the
    /// directory name (or the volume name at the backend root, matching the path bar's root crumb).
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return panel.path.isRoot ? "Macintosh HD" : panel.path.lastComponent
    }
}
