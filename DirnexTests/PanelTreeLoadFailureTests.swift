import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// A tree folder that cannot be listed closes again instead of drawing as open and empty.
///
/// Reported 2026-10-11 against a Synology share whose `#recycle` the mounting account may not list:
/// the list pane learned to say so that day, and the tree went on showing the bin expanded with
/// nothing beneath it, which is what an empty folder looks like. The rule is `navigate`'s. A gesture
/// gets the "Can’t open" sheet, a restore stays quiet, and a live refresh keeps the last good rows.
///
/// The fixture is a real `chmod 000` folder, which fails at `opendir`. The share fails one call
/// later, at `readdir`, and `LocalBackendTests` pins that both throw the same `permissionDenied`;
/// the tree sees only the error.
@MainActor
@Suite("A tree folder that fails to list")
struct PanelTreeLoadFailureTests {
    /// A temporary root holding `locked/` (mode 000, with a file inside that nobody can see) and
    /// `open/` (one file), and a tree pane over it whose view is never loaded.
    @MainActor
    private struct Fixture {
        let directory: URL
        let pane: PanelViewController

        var root: VFSPath { .local(directory.path) }
        var locked: VFSPath { root.appending("locked") }
        var open: VFSPath { root.appending("open") }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PanelTreeLoadFailureTests-\(UUID().uuidString)")
            let manager = FileManager.default
            for name in ["locked", "open"] {
                try manager.createDirectory(
                    at: directory.appendingPathComponent(name),
                    withIntermediateDirectories: true
                )
            }
            try Data("x".utf8).write(to: directory.appendingPathComponent("locked/hidden.txt"))
            try Data("x".utf8).write(to: directory.appendingPathComponent("open/a.txt"))
            try manager.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: directory.appendingPathComponent("locked").path
            )

            let root = VFSPath.local(directory.path)
            pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: root,
                restorationKey: nil
            )
            let entries = try LocalBackend().listDirectory(at: root)
            pane.panel = Panel(
                model: DirectoryModel(listing: DirectoryListing(path: root, entries: entries))
            )
            pane.viewMode = .tree
            pane.applyViewMode()
        }

        /// Give both folders their modes back first, or the removal stops at the one it can't read.
        func remove() {
            for name in ["locked", "open"] {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: directory.appendingPathComponent(name).path
                )
            }
            try? FileManager.default.removeItem(at: directory)
        }

        /// Open `path` and land its listing, the two halves `expandFolder` runs, the second awaited.
        func expand(_ path: VFSPath, duringRestore: Bool = false) async -> TreeChildLoadOutcome {
            pane.panel.expand(path)
            return await pane.performTreeChildLoad(
                pane.treeChildLoadPlan(for: path, duringRestore: duringRestore)
            )
        }
    }

    /// The positive control. Without it, the failures below could be a fixture nothing can list.
    @Test("a readable folder lists beneath its row and stays open")
    func readableFolderLists() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(await fixture.expand(fixture.open) == .listed)
        #expect(fixture.pane.panel.tree?.isExpanded(fixture.open) == true)
        #expect(fixture.pane.panel.displayedEntries.map(\.name) == ["locked", "open", "a.txt"])
    }

    @Test("a folder opened by a gesture that fails to list closes again and is reported")
    func gestureFailureFoldsBackAndReports() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(await fixture.expand(fixture.locked) == .collapsed(reported: true))
        #expect(fixture.pane.panel.tree?.isExpanded(fixture.locked) == false)
        #expect(fixture.pane.panel.tree?.hasListing(for: fixture.locked) == false)
        #expect(fixture.pane.panel.displayedEntries.map(\.name) == ["locked", "open"])
        // Reading `view` to find a window would have loaded it, and its launch listing would then
        // re-seed the tree under this test.
        #expect(fixture.pane.viewIfLoaded == nil)
    }

    /// The whole gesture rather than its awaited half: → on the row runs the load as a task of its
    /// own, so this polls for the row to close.
    @Test("the disclosure toggle on an unreadable folder leaves it closed")
    func toggleLeavesTheRowClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        fixture.pane.toggleTreeExpansion(for: fixture.locked)
        #expect(fixture.pane.panel.tree?.isExpanded(fixture.locked) == true, "it opens at once")
        var polls = 0
        while fixture.pane.panel.tree?.isExpanded(fixture.locked) == true, polls < 500 {
            try? await Task.sleep(for: .milliseconds(20))
            polls += 1
        }
        #expect(fixture.pane.panel.tree?.isExpanded(fixture.locked) == false)
    }

    /// The restore window has to close on this exit too, or a cursor anchored inside the folder waits
    /// for a listing that is never coming.
    @Test("a restored folder that fails to list closes without a report")
    func restoreFailureFoldsBackQuietly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.pane.tabs[0].pendingRestoreTreeLoads = 1

        let outcome = await fixture.expand(fixture.locked, duringRestore: true)

        #expect(outcome == .collapsed(reported: false))
        #expect(fixture.pane.panel.tree?.isExpanded(fixture.locked) == false)
        #expect(fixture.pane.tabs[0].pendingRestoreTreeLoads == 0)
    }

    /// Closed while its listing was out: the question was withdrawn, so nothing is said. The next →
    /// asks again.
    @Test("a folder closed before its failure lands stays closed and says nothing")
    func withdrawnExpansionIsSilent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.pane.panel.expand(fixture.locked)
        let plan = fixture.pane.treeChildLoadPlan(for: fixture.locked)
        fixture.pane.panel.collapse(fixture.locked)

        #expect(await fixture.pane.performTreeChildLoad(plan) == .dropped)
        #expect(fixture.pane.panel.tree?.isExpanded(fixture.locked) == false)
    }

    @Test("a failure landing after the pane moved on changes nothing")
    func staleFailureIsDropped() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.pane.panel.expand(fixture.locked)
        let plan = fixture.pane.treeChildLoadPlan(for: fixture.locked)
        fixture.pane.loadToken += 1

        #expect(await fixture.pane.performTreeChildLoad(plan) == .dropped)
        #expect(fixture.pane.panel.tree?.isExpanded(fixture.locked) == true)
    }

    /// A watcher must not raise a sheet, and a folder that was readable a moment ago is better shown
    /// with the rows it had than closed under the user by an event they didn't cause.
    @Test("a refresh that can no longer list an open folder keeps its rows and stays open")
    func refreshFailureKeepsTheLastListing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(await fixture.expand(fixture.open) == .listed)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: fixture.open.path
        )

        let plan = try #require(fixture.pane.treeRefreshPlan())
        await fixture.pane.performTreeRefresh(plan, selecting: nil, wake: .filesystemEvent)

        #expect(fixture.pane.panel.tree?.isExpanded(fixture.open) == true)
        #expect(fixture.pane.panel.tree?.entries(in: fixture.open)?.map(\.name) == ["a.txt"])
        #expect(fixture.pane.viewIfLoaded == nil)
    }
}
