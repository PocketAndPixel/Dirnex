import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// Get Info in the right-click menus (2026-10-14).
///
/// Over a row the item is the registry's own `file.attributes`, so what it opens is the File menu's
/// decision and is pinned where that lives (`RemoteAttributesTests`). What is pinned here is the
/// menu's half: that the item is there in both item menus, that it validates live, and that a
/// right-click has left it aimed at the row or the marked set the pointer was on. The background
/// menu has an item of its own, aimed at the folder the menu is about.
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

    // MARK: - The folder, from the background menu

    /// The background menu's own item, found by its action. It is not the registry's: that one
    /// would describe the cursor row, which is not what the menu is about.
    private func folderInfoItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.action == NSSelectorFromString("showFolderAttributes:") }
    }

    @Test("the empty space describes the pane's folder, not the row under the cursor")
    func emptySpace() throws {
        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane
        pane.panel.moveCursor(to: 1)

        let menu = pane.contextMenu(forRow: -1)

        #expect(getInfoItem(in: menu) == nil)
        let item = try #require(folderInfoItem(in: menu))
        #expect(item.target === pane)
        #expect(item.representedObject as? VFSPath == .local("/tmp/probe"))
        #expect(item.title == LocalizedCatalog.command(for: "file.attributes")?.title)
        #expect(pane.validateMenuItem(item))
    }

    @Test("the `..` row describes the folder it leads to")
    func parentRow() throws {
        let hosted = windowedPane(showing: rows, at: .local("/tmp/probe"))
        let pane = hosted.pane

        let menu = pane.contextMenu(forRow: 0)

        let item = try #require(folderInfoItem(in: menu))
        #expect(item.representedObject as? VFSPath == .local("/tmp"))
    }

    /// A results tab's hits share no folder, so there is nothing for the item to describe.
    @Test("a search-results tab offers no folder Get Info")
    func resultsTab() {
        let hosted = windowedPane(showing: rows, at: VFSPath(backend: .search, path: "/Results"))
        let pane = hosted.pane

        let menu = pane.contextMenu(forRow: -1)

        #expect(folderInfoItem(in: menu) == nil)
        #expect(menu.items.contains { $0.action == NSSelectorFromString("copyContextPath:") })
    }

    /// The archive's TOC answers its root as `/` with no name and no date; the archive file is what
    /// the user is standing in, and what Copy Path names there.
    @Test("an archive's root describes the archive file, or the member it was opened from")
    func archiveRoot() {
        let zip = "/tmp/probe/bundle.zip"
        let (pane, host) = hostedPane(at: VFSPath(backend: .archive(forArchiveAt: zip), path: "/"))
        defer { _ = host }
        let root = VFSPath(backend: .archive(forArchiveAt: zip), path: "/")

        #expect(pane.folderInfoSubject(for: root) == .local(zip))
        #expect(pane.folderInfoSubject(for: root.appending("docs")) == root.appending("docs"))

        let extracted = "/tmp/dirnex-nested/inner.zip"
        let origin = VFSPath(backend: .archive(forArchiveAt: zip), path: "/sub/inner.zip")
        host.nestedArchiveRegistry.record(mountOnDiskPath: extracted, origin: origin)
        let nestedRoot = VFSPath(backend: .archive(forArchiveAt: extracted), path: "/")
        #expect(pane.folderInfoSubject(for: nestedRoot) == origin)
    }
}
