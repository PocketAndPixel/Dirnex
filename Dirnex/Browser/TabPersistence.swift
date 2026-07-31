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
}

/// Load/save per-pane tab state keyed by a stable pane identifier ("left"/"right").
enum TabPersistence {
    private static let keyPrefix = "Dirnex.tabs."

    static func load(paneKey: String) -> PersistedPane? {
        guard let data = UserDefaults.standard.data(forKey: keyPrefix + paneKey) else { return nil }
        return try? JSONDecoder().decode(PersistedPane.self, from: data)
    }

    static func save(_ pane: PersistedPane, paneKey: String) {
        guard let data = try? JSONEncoder().encode(pane) else { return }
        UserDefaults.standard.set(data, forKey: keyPrefix + paneKey)
    }
}

extension PersistedTab {
    init(path: VFSPath, sort: FileSort, columns: [ColumnLayout]?) {
        backend = path.backend.rawValue
        self.path = path.path
        sortKey = sort.key.rawValue
        sortAscending = sort.ascending
        self.columns = columns
    }

    var vfsPath: VFSPath {
        VFSPath(backend: VFSBackendID(backend), path: path)
    }

    var fileSort: FileSort {
        FileSort(key: FileSort.Key(rawValue: sortKey) ?? .name, ascending: sortAscending)
    }
}
