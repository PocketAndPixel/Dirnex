import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// ⌘[ and ⌘] put the pane back where it was left in the folder they return to: the row the cursor
/// was on, and in a tree the folders that were open, with a cursor inside one of them.
///
/// The core pins that each entry keeps its own spot through everything that reshapes the trail
/// (`NavigationHistorySpotTests`). What is asserted here is the wiring a real pane runs: that leaving
/// a folder writes its spot, that a walk's landing puts it back through the restore a relaunched tab
/// uses, and that a listing that is not a walk does not.
@MainActor
@Suite("History spots")
struct HistorySpotTests {
    /// `a/` holding `one.txt`, `two.txt`, `three.txt` and `sub/nested.txt`, and `b/` holding `b1.txt`
    /// and `b2.txt`. Sorted with folders first, `sub` is `a`'s first row and `b1.txt` is `b`'s, so a
    /// cursor anywhere else was put there.
    @MainActor
    private struct Fixture {
        let directory: URL
        let pane: PanelViewController

        var folderA: VFSPath { .local(directory.appendingPathComponent("a").path) }
        var folderB: VFSPath { .local(directory.appendingPathComponent("b").path) }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("HistorySpotTests-\(UUID().uuidString)")
            let folderA = directory.appendingPathComponent("a")
            try FileManager.default.createDirectory(
                at: folderA.appendingPathComponent("sub"),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("b"),
                withIntermediateDirectories: true
            )
            for name in [
                "a/one.txt",
                "a/two.txt",
                "a/three.txt",
                "a/sub/nested.txt",
                "b/b1.txt",
                "b/b2.txt"
            ] {
                try Data("x".utf8).write(to: directory.appendingPathComponent(name))
            }
            pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: .local(folderA.path),
                restorationKey: nil
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        /// Navigate and wait for the listing and any walk to have landed.
        func go(to path: VFSPath) async throws {
            pane.navigate(to: path)
            try await settled(on: path)
        }

        func settled(on path: VFSPath) async throws {
            try await settleUntil {
                pane.panel.path == path && pane.tabs[0].hasLoaded && pane.tabs[0].history.walk == nil
            }
        }

        func moveCursor(to path: VFSPath) throws {
            pane.panel.moveCursor(to: try #require(pane.panel.displayedIndex(ofID: path)))
            pane.cursorOnParentRow = false
        }
    }

    @Test("⌘[ lands on the row the cursor was on, and ⌘] on the row it left there")
    func walksComeBackToTheRow() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.go(to: fixture.folderA)
        try fixture.moveCursor(to: fixture.folderA.appending("two.txt"))
        try await fixture.go(to: fixture.folderB)
        try fixture.moveCursor(to: fixture.folderB.appending("b2.txt"))

        pane.goBack(nil)
        try await fixture.settled(on: fixture.folderA)
        #expect(pane.panel.currentEntry?.name == "two.txt")

        // Left again somewhere else, which is where the next walk back has to land.
        try fixture.moveCursor(to: fixture.folderA.appending("one.txt"))
        pane.goForward(nil)
        try await fixture.settled(on: fixture.folderB)
        #expect(pane.panel.currentEntry?.name == "b2.txt")

        pane.goBack(nil)
        try await fixture.settled(on: fixture.folderA)
        #expect(pane.panel.currentEntry?.name == "one.txt")
    }

    @Test("⌘[ re-opens the tree folders that were open and lands on the row inside one")
    func walkBackReopensTheTree() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        let sub = fixture.folderA.appending("sub")
        let nested = sub.appending("nested.txt")
        try await fixture.go(to: fixture.folderA)
        pane.viewMode = .tree
        pane.applyViewMode()
        pane.toggleTreeExpansion(for: sub)
        try await settleUntil { pane.panel.displayedIndex(ofID: nested) != nil }
        try fixture.moveCursor(to: nested)
        try await fixture.go(to: fixture.folderB)
        #expect(pane.panel.tree?.expanded.isEmpty == true)

        pane.goBack(nil)
        try await fixture.settled(on: fixture.folderA)
        try await settleUntil { pane.panel.currentEntry?.path == nested }

        #expect(pane.panel.tree?.isExpanded(sub) == true)
        #expect(pane.tabs[0].hasPendingRestore == false)
        #expect(pane.tabs[0].pendingRestoreTreeLoads == 0)
    }

    /// The negative control for both tests above: the same folder reached by a fresh navigation
    /// rather than a walk starts at the top, so the rows they land on are the spot's doing.
    @Test("going to a folder any other way starts at its first row")
    func freshNavigationStartsAtTheTop() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        try await fixture.go(to: fixture.folderA)
        try fixture.moveCursor(to: fixture.folderA.appending("two.txt"))
        try await fixture.go(to: fixture.folderB)

        try await fixture.go(to: fixture.folderA)

        #expect(pane.panel.cursor == 0)
        #expect(pane.panel.currentEntry?.name == "sub")
    }

    @Test("the spots go down with the tab's trail and come back with it")
    func spotsAreWrittenWithTheTrail() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pane = fixture.pane
        pane.restorationKey = "history-spots-\(UUID().uuidString)"
        pane.tabStateDefaults = TabStateScratch.defaults
        try await fixture.go(to: fixture.folderA)
        try fixture.moveCursor(to: fixture.folderA.appending("three.txt"))
        try await fixture.go(to: fixture.folderB)

        let key = try #require(pane.restorationKey)
        let saved = try #require(TabPersistence.load(paneKey: key, from: TabStateScratch.defaults))
        let restored = try #require(PanelViewController.restoredTabs(from: saved).first)
        var history = restored.history
        _ = history.back()
        #expect(history.spot(landingOn: fixture.folderA) == NavigationSpot(cursor: "three.txt"))
    }
}
