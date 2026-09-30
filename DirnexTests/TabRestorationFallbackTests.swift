import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What the **fallback** tab inherits from the tab it stands in for. `restoredTabs` drops any tab
/// whose directory can't be listed at launch — every remote one — so a pane whose only tab was
/// remote reopens on a fresh Home tab, and anything that tab isn't given is silently reverted to a
/// default the user never chose.
///
/// Three fields ride on the last-active tab, and they were fixed one bug report at a time: the
/// **column widths** (`TabRestorationColumnTests`, where a Date column snapped back to 150), the
/// **view mode** — set a pane to a tree, connect to S3, quit, and it came back a flat list, reported
/// 2026-08-20 — and the **sort**, which reverted to name-ascending the same way. Each time, a pane
/// whose tab *was* restored kept the setting while a pane whose tab was dropped lost it, and that
/// asymmetry is what reads as a bug rather than as a default.
@Suite("Tab restoration fallback")
@MainActor
struct TabRestorationFallbackTests {
    /// The account descriptor `S3Account` serializes into a `VFSBackendID`, for the endpoint in the
    /// report — `<scheme><accessKeyID>@<host>:<port>/<region>`, with the account's own `s3a://`.
    private static let s3AccountBackend = "s3a://AKIAEXAMPLE@s3.eu-north-1.amazonaws.com:443/eu-north-1"

    private static func s3Tab(
        viewMode: PanelViewMode,
        sort: FileSort = .default
    ) -> PersistedTab {
        PersistedTab(
            backend: s3AccountBackend,
            path: "/",
            sortKey: sort.key.rawValue,
            sortAscending: sort.ascending,
            columns: nil,
            viewMode: viewMode.rawValue
        )
    }

    private static func localTab(viewMode: PanelViewMode) -> PersistedTab {
        PersistedTab(
            path: .local(NSHomeDirectory()),
            sort: .default,
            columns: nil,
            viewMode: viewMode
        )
    }

    private static func restore(_ pane: PersistedPane) -> (tabs: [PanelTab], activeIndex: Int) {
        PanelViewController.restoredLayout(
            from: pane,
            defaultPath: .local(NSHomeDirectory()),
            showHidden: false
        )
    }

    @Test("the active tab's shape is what a fallback inherits, clamped to the stored tabs")
    func activeTabViewMode() {
        let pane = PersistedPane(
            tabs: [Self.localTab(viewMode: .list), Self.s3Tab(viewMode: .tree)],
            activeIndex: 1
        )
        #expect(pane.activeTabViewMode == .tree)

        // A stale index (a tab count that shrank) must not trap — fall back to the first tab.
        let outOfRange = PersistedPane(tabs: [Self.s3Tab(viewMode: .tree)], activeIndex: 5)
        #expect(outOfRange.activeTabViewMode == .tree)
    }

    @Test("a pane whose only tab was S3 reopens at Home still a tree")
    func remoteOnlyPaneKeepsTreeMode() {
        let layout = Self.restore(PersistedPane(tabs: [Self.s3Tab(viewMode: .tree)], activeIndex: 0))
        // The S3 tab is dropped (it can't be listed at launch), so one fresh Home tab stands in…
        #expect(layout.tabs.count == 1)
        #expect(layout.tabs[0].panel.path.backend == .local)
        // …still drawing the shape the user set, rather than reverting to a flat list.
        #expect(layout.tabs[0].viewMode == .tree)
    }

    /// The narrowness control: the carry-forward must not *impose* a tree on a pane that was a list,
    /// which is the failure a blanket default would introduce.
    @Test("a pane whose only tab was a list S3 tab reopens at Home a list")
    func remoteOnlyPaneKeepsListMode() {
        let layout = Self.restore(PersistedPane(tabs: [Self.s3Tab(viewMode: .list)], activeIndex: 0))
        #expect(layout.tabs.count == 1)
        #expect(layout.tabs[0].viewMode == .list)
    }

    @Test("a restored local tab keeps its own shape — the wrapper doesn't touch the happy path")
    func localTabRestoresUnchanged() {
        let pane = PersistedPane(tabs: [Self.localTab(viewMode: .tree)], activeIndex: 0)
        let layout = Self.restore(pane)
        #expect(layout.tabs.count == 1)
        #expect(layout.tabs[0].panel.path == pane.tabs[0].vfsPath)
        #expect(layout.tabs[0].viewMode == .tree)
    }

    /// The half a persisted string cannot answer: the mode has to seed a *real* tree, or the tab
    /// records `.tree` while the pane goes on drawing a flat list — the model-and-screen disagreement
    /// this codebase keeps meeting. Driven through the pane's own `init` (which calls
    /// `restoredLayout`) and `applyViewMode`, the call `navigate` makes right after `setModel`.
    @Test("the carried-forward shape seeds an actual tree on the restored pane")
    func fallbackPaneDrawsATree() {
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: PersistedPane(tabs: [Self.s3Tab(viewMode: .tree)], activeIndex: 0),
            defaultPath: .local(NSHomeDirectory()),
            restorationKey: nil
        )
        #expect(pane.tabs.count == 1)
        #expect(pane.viewMode == .tree)
        // A pane holds a model from the moment it is built; `applyViewMode` is what turns the tab's
        // recorded shape into `panel.tree`.
        #expect(!pane.panel.isTree)
        pane.applyViewMode()
        #expect(pane.panel.isTree)
    }

    /// Its narrowness control: a list-mode remote tab must leave the fallback pane flat, or the
    /// carry-forward has quietly become "always open a tree".
    @Test("a list-mode remote tab leaves the restored pane flat")
    func fallbackPaneStaysFlat() {
        let pane = PanelViewController(
            backend: LocalBackend(),
            restoration: PersistedPane(tabs: [Self.s3Tab(viewMode: .list)], activeIndex: 0),
            defaultPath: .local(NSHomeDirectory()),
            restorationKey: nil
        )
        #expect(pane.viewMode == .list)
        pane.applyViewMode()
        #expect(!pane.panel.isTree)
    }

    @Test("first launch (no persisted state) opens one Home tab as a flat list")
    func firstLaunchIsAList() {
        let layout = PanelViewController.restoredLayout(
            from: nil,
            defaultPath: .local(NSHomeDirectory()),
            showHidden: false
        )
        #expect(layout.tabs.count == 1)
        #expect(layout.tabs[0].viewMode == .list)
    }

    // MARK: - Sort

    /// Newest-first: the order a user sets and then loses, and deliberately *not* the default on
    /// either axis, so a fallback that ignored the stored sort can't pass by coincidence.
    private static let newestFirst = FileSort(key: .modified, ascending: false)

    @Test("the active tab's sort is what a fallback inherits, clamped to the stored tabs")
    func activeTabSort() {
        let pane = PersistedPane(
            tabs: [
                Self.localTab(viewMode: .list),
                Self.s3Tab(viewMode: .list, sort: Self.newestFirst)
            ],
            activeIndex: 1
        )
        #expect(pane.activeTabSort == Self.newestFirst)

        // A stale index (a tab count that shrank) must not trap — fall back to the first tab.
        let outOfRange = PersistedPane(
            tabs: [Self.s3Tab(viewMode: .list, sort: Self.newestFirst)],
            activeIndex: 5
        )
        #expect(outOfRange.activeTabSort == Self.newestFirst)
    }

    @Test("a pane whose only tab was S3 reopens at Home still sorted the way the user left it")
    func remoteOnlyPaneKeepsSort() {
        let layout = Self.restore(
            PersistedPane(
                tabs: [Self.s3Tab(viewMode: .list, sort: Self.newestFirst)],
                activeIndex: 0
            )
        )
        #expect(layout.tabs.count == 1)
        #expect(layout.tabs[0].panel.path.backend == .local)
        #expect(layout.tabs[0].panel.model.sort == Self.newestFirst)
    }

    /// The narrowness control: a tab stored at the default order must not come back re-sorted.
    @Test("a default-sorted remote tab reopens at Home on the default sort")
    func remoteOnlyPaneKeepsDefaultSort() {
        let layout = Self.restore(PersistedPane(tabs: [Self.s3Tab(viewMode: .list)], activeIndex: 0))
        #expect(layout.tabs[0].panel.model.sort == .default)
    }

    @Test("first launch (no persisted state) opens one Home tab on the default sort")
    func firstLaunchUsesDefaultSort() {
        let layout = PanelViewController.restoredLayout(
            from: nil,
            defaultPath: .local(NSHomeDirectory()),
            showHidden: false
        )
        #expect(layout.tabs[0].panel.model.sort == .default)
    }
}
