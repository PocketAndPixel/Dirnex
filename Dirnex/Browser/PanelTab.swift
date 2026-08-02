import DirnexCore
import Foundation

/// Which *shape* a tab draws its listing in (PLAN.md §M15 Slice 4).
///
/// Per **tab**, not app-wide, so one pane can be a tree while the other stays a list — which is the
/// whole point of comparing two places at once. And **persisted**, unlike the per-tab
/// `isSizeVisualizationEnabled`, which is the precedent this must not copy: size bars are a mode you
/// switch on to answer a question and are done with, while a tab restored into the wrong shape reads
/// as data loss.
///
/// `.tree` is accepted and round-trips through persistence from Slice 1 onward; nothing reads it
/// yet, so a tab in it still renders as `.list` until Slice 4 lands.
enum PanelViewMode: String, CaseIterable {
    case list
    case tree
}

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
    /// The cursor and marks to re-apply once a *restored* tab's directory first lists, as paths
    /// relative to the tab's root (the shape `PersistedTab` stores) matched by identity against the
    /// fresh listing, so a file deleted since quit is simply dropped (PLAN.md §M1 "restored on
    /// relaunch"; the identity-not-index rule the cursor already follows across a live refresh).
    /// Seeded from the on-disk `PersistedTab` in `restoredTabs`, consumed by
    /// `PanelViewController.applyPendingRestore`; all `nil`/`false` for a tab that was not restored
    /// from disk, which makes the re-apply a no-op there.
    var pendingCursorPath: String?
    var pendingCursorOnParent = false
    var pendingMarkPaths: [String]?
    /// How many of a restored *tree's* per-folder listings are still in flight (PLAN.md §M15 Slice
    /// 4). A cursor or a mark inside an expanded folder has no row to anchor on until that folder
    /// has listed, so the pending state above outlives the root's load and is re-applied as each
    /// child lands; this is what says whether another landing is still coming. Zero for a flat list,
    /// which is what makes the restore one-shot there.
    var pendingRestoreTreeLoads = 0
    /// The tree folders to re-open once a *restored* tree tab's directory first lists (PLAN.md §M15
    /// Slice 4), as paths relative to the tab's root — matching the shape `PersistedTab` stores.
    /// Consumed and cleared by `restorePendingTreeExpansion` on the first load; `nil` for a tab that
    /// was not restored from disk or was a flat list, which makes the re-open a no-op.
    var pendingExpandedPaths: [String]?
    /// This tab's column widths/order, in display order (UI-only, like `cursorOnParentRow`;
    /// see `PanelViewController+Columns`). `nil` until the tab has been given an explicit
    /// layout — restored from disk or inherited from the tab it was spawned from — in which
    /// case the pane falls back to the default columns.
    var columnLayout: [ColumnLayout]?
    /// The shape this tab draws its listing in (PLAN.md §M15), persisted beside `columnLayout` and
    /// inherited by a tab spawned from this one, exactly as the sort and the columns are.
    var viewMode: PanelViewMode = .list
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
    /// The real directories a **merged** listing was assembled from — every trash for the Trash
    /// (PLAN.md §M8), the CloudDocs container plus each app library for iCloud Drive (§M9). Empty
    /// for every other kind of tab.
    ///
    /// Held because such a tab has no directory of its own to watch, and yet its contents change
    /// behind the pane's back: trashing a file in Finder must show up in an open Trash tab without
    /// re-clicking the row. The pane watches exactly these, through one FSEvents stream, and
    /// re-gathers when any of them changes. Recorded by the gather that produced the listing, so it
    /// always describes what is actually on screen. Session-scoped like the snapshots above.
    var mergedSources: [VFSPath] = []

    /// Drop everything that describes *results* rather than a place: the chip label and the query
    /// behind "Save Search…". Called when the tab stops showing a results listing — navigating a
    /// Trash or search tab to a real folder — because those three outlive the listing otherwise,
    /// and a tab sitting in Home still chipped "Trash" is a lie about where the pane is (found
    /// live). Also what a tab reset to Home reaches for when its directory vanishes.
    func clearResultsIdentity() {
        customTitle = nil
        searchQuery = nil
        searchScope = nil
        mergedSources = []
    }

    /// Whether this tab still has a restored cursor or marks waiting to be anchored.
    var hasPendingRestore: Bool {
        pendingCursorPath != nil || pendingCursorOnParent || pendingMarkPaths != nil
    }

    /// Drop whatever never resolved — a file deleted since quit, or one inside a folder that failed
    /// to list — so a later navigation in this tab starts clean.
    func clearPendingRestore() {
        pendingCursorPath = nil
        pendingCursorOnParent = false
        pendingMarkPaths = nil
    }

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
    ///
    /// Only the *local* root is the volume: at an archive's or an SFTP account's root the path bar
    /// names the archive file / the account, so a bare "Macintosh HD" there contradicted the crumb
    /// trail right below it (`displayName` is the shared answer, and the load-failure sheet's too).
    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if panel.path.isRoot, panel.path.backend == .local { return "Macintosh HD" }
        return panel.path.displayName
    }
}
