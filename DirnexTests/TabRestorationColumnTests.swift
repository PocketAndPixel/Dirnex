import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A pane's column widths are stored per tab (PLAN.md §M1). A remote (FTP/SFTP/SMB) folder can't be
/// listed at launch without reconnecting, so `restoredTabs` drops such a tab rather than open onto a
/// dead path — and dropping it used to take the user's column widths with it: a pane whose only tab
/// was FTP came back at the *default* layout, so the Date column visibly snapped from a hand-set
/// width back to 150, while a plain local folder (whose tab *is* restored) kept its width. That
/// asymmetry is the reported bug; `restoredLayout` closes it by carrying the last-active tab's
/// columns onto the fallback Home tab.
@Suite("Tab restoration column layout")
@MainActor
struct TabRestorationColumnTests {
    /// A believable FTP descriptor — the form `FTPLocation` serializes into a `VFSBackendID`
    /// (`<scheme>user@host:port`).
    private static let ftpBackend = "ftp://reports@ftp.example.com:21"

    private static let resizedColumns = [
        ColumnLayout(id: "name", width: 263),
        ColumnLayout(id: "size", width: 90),
        // The tell in the report: a Date column dragged narrower than its 150 default.
        ColumnLayout(id: "date", width: 124)
    ]

    private static func ftpTab(columns: [ColumnLayout]?) -> PersistedTab {
        PersistedTab(
            backend: ftpBackend,
            path: "/",
            sortKey: "name",
            sortAscending: true,
            columns: columns
        )
    }

    private static func localTab(columns: [ColumnLayout]?) -> PersistedTab {
        PersistedTab(
            backend: VFSBackendID.local.rawValue,
            path: NSHomeDirectory(),
            sortKey: "name",
            sortAscending: true,
            columns: columns
        )
    }

    @Test("the active tab's columns are what a fallback inherits, clamped to the stored tabs")
    func activeTabColumns() {
        let pane = PersistedPane(
            tabs: [Self.localTab(columns: nil), Self.ftpTab(columns: Self.resizedColumns)],
            activeIndex: 1
        )
        #expect(pane.activeTabColumns == Self.resizedColumns)

        // A stale index (a tab count that shrank) must not trap — fall back to the first tab.
        let outOfRange = PersistedPane(
            tabs: [Self.ftpTab(columns: Self.resizedColumns)],
            activeIndex: 5
        )
        #expect(outOfRange.activeTabColumns == Self.resizedColumns)
    }

    @Test("a pane whose only tab was FTP reopens at Home keeping the widths the user set")
    func remoteOnlyPaneKeepsColumnWidths() {
        let pane = PersistedPane(tabs: [Self.ftpTab(columns: Self.resizedColumns)], activeIndex: 0)
        let layout = PanelViewController.restoredLayout(
            from: pane,
            defaultPath: .local(NSHomeDirectory()),
            showHidden: false
        )
        // The FTP tab is dropped (it can't be listed at launch), so one fresh Home tab stands in…
        #expect(layout.tabs.count == 1)
        #expect(layout.activeIndex == 0)
        #expect(layout.tabs[0].panel.path.backend == .local)
        // …carrying the column widths forward rather than reverting to the defaults.
        #expect(layout.tabs[0].columnLayout == Self.resizedColumns)
    }

    @Test("a restored local tab keeps its own columns — the wrapper doesn't touch the happy path")
    func localTabRestoresUnchanged() {
        let pane = PersistedPane(tabs: [Self.localTab(columns: Self.resizedColumns)], activeIndex: 0)
        let layout = PanelViewController.restoredLayout(
            from: pane,
            defaultPath: .local(NSHomeDirectory()),
            showHidden: false
        )
        #expect(layout.tabs.count == 1)
        #expect(layout.tabs[0].panel.path == pane.tabs[0].vfsPath)
        #expect(layout.tabs[0].columnLayout == Self.resizedColumns)
    }

    @Test("first launch (no persisted state) opens one Home tab on the default column layout")
    func firstLaunchUsesDefaults() {
        let layout = PanelViewController.restoredLayout(
            from: nil,
            defaultPath: .local(NSHomeDirectory()),
            showHidden: false
        )
        #expect(layout.tabs.count == 1)
        // No stored layout → `nil`, which `applyColumnLayout` reads as "use the defaults".
        #expect(layout.tabs[0].columnLayout == nil)
    }
}
