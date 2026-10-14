import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Get Info in the right-click menu over a row (2026-10-14).
///
/// The item is the registry's own `file.attributes`, so what it opens is the File menu's decision and
/// is pinned where that lives (`RemoteAttributesTests`). What is pinned here is the menu's half: that
/// the item is there in both item menus, that it validates live, and that a right-click has left it
/// aimed at the row or the marked set the pointer was on.
@MainActor
@Suite("Context menu ▸ Get Info")
struct ContextMenuGetInfoTests {
    private let rows = ["a.txt", "b.txt", "c.txt"].map { Handoff.local("/tmp/\($0)") }

    /// Found by action rather than title, so the test reads the same in every language.
    private func getInfoItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.action == #selector(PanelViewController.showAttributes(_:)) }
    }

    @Test("a right-click on one row offers Get Info for that row")
    func oneRow() throws {
        let hosted = windowedPane(showing: rows)
        let pane = hosted.pane

        let menu = pane.contextMenu(forRow: pane.row(forEntryIndex: 1))

        let item = try #require(getInfoItem(in: menu))
        #expect(pane.validateMenuItem(item))
        #expect(pane.attributesTargets().map(\.name) == ["b.txt"])
        #expect(AttributesRoute.decide(for: pane.attributesTargets()) == .single)
    }

    @Test("a right-click inside a marked set offers Get Info for the whole set")
    func markedSet() throws {
        let hosted = windowedPane(showing: rows)
        let pane = hosted.pane
        pane.panel.setSelection([rows[0].path, rows[2].path])

        let menu = pane.contextMenu(forRow: pane.row(forEntryIndex: 2))

        let item = try #require(getInfoItem(in: menu))
        #expect(pane.validateMenuItem(item))
        #expect(Set(pane.attributesTargets().map(\.name)) == ["a.txt", "c.txt"])
        #expect(AttributesRoute.decide(for: pane.attributesTargets()) == .multiple)
    }

    /// The Trash builds its own item menu, and a trashed row carries its real local path, so the
    /// ordinary panel describes it.
    @Test("a trashed row offers Get Info too")
    func trashedRow() throws {
        let trashed = Handoff.local(NSHomeDirectory() + "/.Trash/old.txt")
        let hosted = windowedPane(showing: [trashed], at: VFSPath(backend: .trash, path: "/Trash"))
        let pane = hosted.pane
        #expect(pane.isTrashListing)

        let menu = pane.contextMenu(forRow: pane.row(forEntryIndex: 0))

        let item = try #require(getInfoItem(in: menu))
        #expect(pane.validateMenuItem(item))
        #expect(AttributesRoute.decide(for: pane.attributesTargets()) == .single)
    }
}
