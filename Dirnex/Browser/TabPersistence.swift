import DirnexCore
import Foundation

/// On-disk snapshot of one pane's tabs, restored on relaunch (PLAN.md §M1 "tabs …
/// restored on relaunch" + "sort/column state per tab, persisted"). Deliberately
/// boring JSON in `UserDefaults` — see PLAN.md §2 "JSON/plist for config".
/// One column's on-screen geometry, persisted per tab (PLAN.md §M1 "column width/order
/// per tab"). The position in the array *is* the display order; `width` is in points.
/// Shared verbatim between the in-memory `PanelTab` and the on-disk `PersistedTab`.
struct ColumnLayout: Codable, Equatable {
    var id: String
    var width: Double
}

struct PersistedTab: Codable {
    var backend: String
    var path: String
    var sortKey: String
    var sortAscending: Bool
    /// Column widths/order, in display order. Optional so tab state written before this
    /// field existed still decodes (a missing key → `nil` → default columns).
    var columns: [ColumnLayout]?
    /// Which shape this tab drew its listing in (PLAN.md §M15), as `PanelViewMode.rawValue`.
    ///
    /// The raw string rather than the enum, matching `sortKey` right above it and for a reason
    /// worth stating: a `Codable` enum *throws* on an unknown case, and because every field here is
    /// decoded as one `PersistedTab`, a mode written by a newer build would fail the whole tab's
    /// decode and drop it out of the restored session. Read back through
    /// `panelViewMode`, which falls back to `.list`.
    var viewMode: String?
    /// The tree folders that were expanded, as paths relative to this tab's root (PLAN.md §M15 Slice
    /// 4) — so a relaunched tree comes back opened to where the user left it. Optional and omitted
    /// when empty (list mode, or an all-collapsed tree), so the common case adds nothing to the JSON.
    var expandedPaths: [String]?
    /// The entry the cursor was on, as a path **relative to this tab's root** — so a relaunched tab
    /// re-anchors on the *same entry by identity* rather than a row index, matching how `Panel` keeps
    /// the cursor across a live refresh (row indices are meaningless once sort/contents drift). `nil`
    /// when the cursor sat on `..` or the directory was empty. Optional, like every field below, so
    /// state written before these existed still decodes (a missing key → `nil`).
    ///
    /// Relative rather than a bare leaf name because a **tree** row can sit inside an expanded
    /// folder (`jMeter/Synergie.zip`), which a leaf name cannot address — the same anchoring, and
    /// the same spelling, `expandedPaths` right above uses. A flat list only ever writes a single
    /// component, which is exactly what a leaf name was.
    var cursorPath: String?
    /// The cursor was parked on the synthetic `..` row (UI-only state; see `PanelTab`).
    var cursorOnParent: Bool?
    /// The marked entries, as root-relative paths like `cursorPath` (and for the same tree reason),
    /// re-marked on restore by matching against the fresh listing — entries that have since vanished
    /// are dropped, mirroring how a live refresh prunes marks. `nil` (not `[]`) when nothing was
    /// marked, so the common case stays out of the JSON.
    var markedPaths: [String]?
    /// Where to reconnect before this tab can list, for a tab on a connected account
    /// (docs/LOCATION-SUPPORT.md ▸ "Session restore and workspaces drop remote tabs"). Absent for
    /// every local and archive tab, which need no connection at all.
    ///
    /// `backend` above is only the account's **descriptor** — host, user, port, region — which is
    /// what a `VFSBackendID` carries and is not enough to reconnect: it says nothing about the auth
    /// *method*, or about an FTPS certificate the user chose to trust. This is that, and it is
    /// stored on the tab rather than looked up in the sidebar's saved servers for two reasons: a
    /// server connected once from the Connect sheet and never saved still comes back, and deleting a
    /// sidebar row does not silently un-restore the tabs pointing at it. It holds no secret — the
    /// same argument ``ServerConnection`` makes for its own JSON — and the host and username were
    /// already here, inside `backend`, before this field existed.
    ///
    /// Read it through ``serverEndpoint``: ``StoredServerEndpoint`` degrades a shape this build
    /// cannot read to `nil` instead of throwing, which matters more here than anywhere, because a
    /// pane's tabs are one array in one blob — a throw would empty the pane rather than drop a tab.
    var endpoint: StoredServerEndpoint?
    /// The tab's back/forward trail, so ⌘[, ⌘] and the ⌥↓ list still know where it has been after a
    /// relaunch. Absent for a tab that has been nowhere else, which is most of them, and for state
    /// written before trails were kept.
    ///
    /// Safe to add to a blob that holds a whole pane's tabs because ``StoredNavigationHistory``
    /// decodes to an empty trail rather than throwing, so an unreadable one costs only itself. What
    /// it leaves out — a vault, a nested archive, a listing that cannot be restored, a server with no
    /// way back — is decided when it is written (`NavigationHistory.stored`).
    var history: StoredNavigationHistory?
}

struct PersistedPane: Codable {
    var tabs: [PersistedTab]
    var activeIndex: Int

    /// The column layout of the tab that was active when this pane was saved, clamped to the stored
    /// tabs. Used to seed the fallback Home tab when every persisted tab pointed at a directory that
    /// can't be restored at launch — a remote (FTP/SFTP/SMB) folder needing reconnection, or a
    /// since-deleted local path — so the pane keeps the column widths the user set instead of
    /// snapping back to the defaults. See `PanelViewController.restoredLayout`.
    var activeTabColumns: [ColumnLayout]? {
        guard tabs.indices.contains(activeIndex) else { return tabs.first?.columns }
        return tabs[activeIndex].columns
    }

    /// The shape the tab that was active when this pane was saved drew in, clamped to the stored
    /// tabs the same way ``activeTabColumns`` is — and used for the same reason, one field over.
    ///
    /// A pane whose every persisted tab was dropped falls back to a Home tab, and building that at
    /// the plain default took the user's tree mode down with the dropped tab: set a pane to a tree,
    /// connect to S3, quit, and the pane reopened a flat list, while a pane whose tab *was* restored
    /// kept its shape. Reported 2026-08-20. `.list` when nothing was stored, which is what a fresh
    /// tab is anyway.
    var activeTabViewMode: PanelViewMode {
        guard tabs.indices.contains(activeIndex) else { return tabs.first?.panelViewMode ?? .list }
        return tabs[activeIndex].panelViewMode
    }

    /// The sort the tab that was active when this pane was saved was ordered by — the third and last
    /// field a dropped tab was carrying, clamped like the two above and added for the same reason.
    /// A pane whose only tab was remote came back sorted by name ascending however the user had left
    /// it, so a pane set to newest-first reverted on every relaunch while a pane on a local folder
    /// kept its order. `.default` when nothing was stored, which is what a fresh tab uses.
    var activeTabSort: FileSort {
        guard tabs.indices.contains(activeIndex) else { return tabs.first?.fileSort ?? .default }
        return tabs[activeIndex].fileSort
    }
}

/// Load/save per-pane tab state keyed by a stable pane identifier ("left"/"right").
///
/// The domain is an argument with no default, so every caller says where a pane's tabs go. The app
/// test target runs inside the app, where `.standard` is the developer's own `app.dirnex.Dirnex`,
/// and a test that wrote there by default left a key behind on every run (docs/NOTES.md ▸ Testing).
enum TabPersistence {
    private static let keyPrefix = "Dirnex.tabs."
    private static let activePaneKey = "Dirnex.activePane"

    static func load(paneKey: String, from defaults: UserDefaults) -> PersistedPane? {
        guard let data = defaults.data(forKey: keyPrefix + paneKey) else { return nil }
        return try? JSONDecoder().decode(PersistedPane.self, from: data)
    }

    static func save(_ pane: PersistedPane, paneKey: String, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(pane) else { return }
        defaults.set(data, forKey: keyPrefix + paneKey)
    }

    /// The pane identifier ("left"/"right") that held focus when the session was last saved, so a
    /// relaunch restores focus to the pane the user was actually in rather than always snapping to
    /// the left. `nil` until a session has been saved (a first launch).
    static func loadActivePane() -> String? {
        UserDefaults.standard.string(forKey: activePaneKey)
    }

    static func saveActivePane(_ paneKey: String) {
        UserDefaults.standard.set(paneKey, forKey: activePaneKey)
    }
}

extension PersistedTab {
    init(
        path: VFSPath,
        sort: FileSort,
        columns: [ColumnLayout]?,
        viewMode: PanelViewMode = .list,
        expandedPaths: [String]? = nil,
        cursorPath: String? = nil,
        cursorOnParent: Bool = false,
        markedPaths: [String]? = nil,
        endpoint: ServerEndpoint? = nil,
        history: StoredNavigationHistory? = nil
    ) {
        backend = path.backend.rawValue
        self.path = path.path
        sortKey = sort.key.rawValue
        sortAscending = sort.ascending
        self.columns = columns
        self.viewMode = viewMode.rawValue
        self.expandedPaths = expandedPaths
        self.cursorPath = cursorPath
        self.cursorOnParent = cursorOnParent
        self.markedPaths = markedPaths
        // `map`, so a local tab writes no field rather than a null — and so a `nil` read back out of
        // a stored one can only ever mean "written, and unreadable by this build".
        self.endpoint = endpoint.map(StoredServerEndpoint.init)
        self.history = history
    }

    var vfsPath: VFSPath {
        VFSPath(backend: VFSBackendID(backend), path: path)
    }

    var fileSort: FileSort {
        FileSort(key: FileSort.Key(rawValue: sortKey) ?? .name, ascending: sortAscending)
    }

    /// The stored shape, or `.list` for state written before the field existed — and for a value a
    /// newer build wrote that this one has never heard of. Tolerant on purpose: a tab is worth
    /// keeping in the wrong shape, never worth dropping.
    var panelViewMode: PanelViewMode {
        PanelViewMode(rawValue: viewMode ?? "") ?? .list
    }

    /// Where to reconnect, or `nil` for a tab that needs no connection — and for one whose stored
    /// endpoint this build cannot read, which is a tab that will simply not be restored
    /// (``TabRestorePolicy`` refuses a remote path with no endpoint rather than bringing back a
    /// chip nothing could ever fill).
    var serverEndpoint: ServerEndpoint? { endpoint?.endpoint }
}
