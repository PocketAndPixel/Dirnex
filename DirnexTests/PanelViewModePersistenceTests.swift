import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A tab's *shape* is per-tab and persisted (PLAN.md §M15 Slice 1). Nothing renders `.tree` yet —
/// that is Slice 4 — so what these pin is the round trip and, more importantly, the two ways it
/// could fail quietly on someone's real session.
@Suite("Panel view mode persistence")
@MainActor
struct PanelViewModePersistenceTests {
    private static func tab(viewMode: PanelViewMode) -> PersistedTab {
        PersistedTab(
            path: .local(NSHomeDirectory()),
            sort: .default,
            columns: nil,
            viewMode: viewMode
        )
    }

    @Test("a tree tab comes back a tree, through JSON and through restoredTabs")
    func treeSurvivesRelaunch() throws {
        let pane = PersistedPane(tabs: [Self.tab(viewMode: .tree)], activeIndex: 0)
        // Through the real encoder/decoder, not just the struct — persistence is JSON on disk.
        let data = try JSONEncoder().encode(pane)
        let decoded = try JSONDecoder().decode(PersistedPane.self, from: data)
        #expect(decoded.tabs[0].panelViewMode == .tree)

        let restored = PanelViewController.restoredTabs(from: decoded)
        #expect(restored.count == 1)
        #expect(restored[0].viewMode == .tree)
    }

    @Test("a list tab stays a list — the default path is untouched")
    func listIsTheDefault() {
        let pane = PersistedPane(tabs: [Self.tab(viewMode: .list)], activeIndex: 0)
        let restored = PanelViewController.restoredTabs(from: pane)
        #expect(restored[0].viewMode == .list)
        #expect(PanelTab(path: .local(NSHomeDirectory())).viewMode == .list)
    }

    /// The upgrade case: tab state written by a build that predates the field has no key at all.
    @Test("state written before the field existed decodes as a list, not a decode failure")
    func absentKeyDecodesAsList() throws {
        let json = """
        {"tabs":[{"backend":"local","path":"\(NSHomeDirectory())",\
        "sortKey":"name","sortAscending":true}],"activeIndex":0}
        """
        let decoded = try JSONDecoder().decode(
            PersistedPane.self, from: Data(json.utf8)
        )
        #expect(decoded.tabs[0].viewMode == nil)
        #expect(decoded.tabs[0].panelViewMode == .list)
        #expect(PanelViewController.restoredTabs(from: decoded).first?.viewMode == .list)
    }

    /// The *downgrade* case, and the reason the field is stored as a `String?` rather than as the
    /// enum: a `Codable` enum throws on an unknown case, and the throw would take the whole
    /// `PersistedTab` with it — so a shape written by a newer build would not merely be ignored, it
    /// would drop the tab out of the restored session. The tab is worth keeping in the wrong shape.
    @Test("a shape a newer build wrote falls back to list instead of dropping the tab")
    func unknownModeKeepsTheTab() throws {
        let json = """
        {"tabs":[{"backend":"local","path":"\(NSHomeDirectory())",\
        "sortKey":"name","sortAscending":true,"viewMode":"columns"}],"activeIndex":0}
        """
        let decoded = try JSONDecoder().decode(
            PersistedPane.self, from: Data(json.utf8)
        )
        #expect(decoded.tabs[0].panelViewMode == .list)
        let restored = PanelViewController.restoredTabs(from: decoded)
        #expect(restored.count == 1)
        #expect(restored[0].viewMode == .list)
    }
}
