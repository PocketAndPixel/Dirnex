import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A link followed in Quick View moves the pane's cursor onto the file it names (PLAN.md §M39 ▸
/// Slice 5): a step within the folder on screen, a landing in the target's folder with the departed
/// one left on the trail for Back, nothing at all for a target that is not there, and a new tab from a
/// results listing so the results survive.
@MainActor
@Suite("Following a link moves the pane")
struct LinkTargetPaneTests {
    /// `a/` holding `README.md` and `sibling.md`, `b/` holding `target.md`, `c/` holding `real.md`.
    @MainActor
    private struct Fixture {
        let directory: URL
        let pane: PanelViewController

        func folder(_ name: String) -> VFSPath { .local(directory.appendingPathComponent(name).path) }
        func file(_ path: String) -> VFSPath { .local(directory.appendingPathComponent(path).path) }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LinkTargetPaneTests-\(UUID().uuidString)")
            for folder in ["a", "b", "c"] {
                try FileManager.default.createDirectory(
                    at: directory.appendingPathComponent(folder),
                    withIntermediateDirectories: true
                )
            }
            for name in ["a/README.md", "a/sibling.md", "b/target.md", "c/real.md"] {
                try Data("x".utf8).write(to: directory.appendingPathComponent(name))
            }
            pane = PanelViewController(
                backend: CompositeBackend(local: LocalBackend()),
                restoration: nil,
                defaultPath: .local(directory.appendingPathComponent("a").path),
                restorationKey: nil
            )
            // Loaded now, as `ResultsInPlaceTests` explains: a landing focuses the table, which
            // would otherwise load the view then and re-list the tab in front.
            pane.loadViewIfNeeded()
            NotificationCenter.default.removeObserver(pane)
        }

        func remove() {
            pane.watcher = nil
            try? FileManager.default.removeItem(at: directory)
        }

        func settled(on path: VFSPath) async throws {
            try await settleUntil {
                pane.panel.path == path && pane.tabs[pane.activeTabIndex].hasLoaded
                    && pane.tabs[pane.activeTabIndex].history.walk == nil
            }
        }

        /// In `a`, with the cursor on `README.md`, the document the links are in.
        func openReadme() async throws {
            pane.navigate(to: folder("a"))
            try await settled(on: folder("a"))
            pane.moveCursor(onto: file("a/README.md"))
        }
    }

    @Test("a sibling the folder lists takes one cursor step, at once")
    func sibling() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.openReadme()
        #expect(fixture.pane.quickViewSourceLocation == fixture.file("a/README.md"))

        fixture.pane.revealLinkTarget(fixture.file("a/sibling.md"))

        #expect(fixture.pane.panel.path == fixture.folder("a"))
        #expect(fixture.pane.quickViewSourceLocation == fixture.file("a/sibling.md"))
    }

    @Test(
        "a file in another folder enters it with the cursor on the file, and Back has the way home"
    )
    func otherFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.openReadme()

        fixture.pane.revealLinkTarget(fixture.file("b/target.md"))
        try await fixture.settled(on: fixture.folder("b"))

        #expect(fixture.pane.quickViewSourceLocation == fixture.file("b/target.md"))
        let history = fixture.pane.tabs[fixture.pane.activeTabIndex].history
        #expect(history.entries == [fixture.folder("a"), fixture.folder("b")])
        #expect(history.canGoBack)
    }

    @Test("a file that is not there leaves the pane where it was")
    func missing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.openReadme()

        // `b` exists and `nope.md` does not, so a pane that went ahead would land in `b`. A local
        // listing lands in milliseconds, which is what the wait is sized against.
        fixture.pane.revealLinkTarget(fixture.file("b/nope.md"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(fixture.pane.panel.path == fixture.folder("a"))
        #expect(fixture.pane.quickViewSourceLocation == fixture.file("a/README.md"))

        // The control: the same pane, the same route, a file that is there.
        fixture.pane.revealLinkTarget(fixture.file("c/real.md"))
        try await fixture.settled(on: fixture.folder("c"))
        #expect(fixture.pane.quickViewSourceLocation == fixture.file("c/real.md"))
        let history = fixture.pane.tabs[fixture.pane.activeTabIndex].history
        #expect(history.entries == [fixture.folder("a"), fixture.folder("c")])
    }

    @Test("from a results listing the target opens in a new tab, and the results stay")
    func fromResults() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try await fixture.openReadme()
        let readme = try #require(fixture.pane.panel.currentEntry)
        fixture.pane.landResults(
            [readme],
            as: .init(
                pathSummary: PanelViewController.ResultsPresentation.recentsIdentity,
                sort: RecentsQuery.resultSort,
                query: nil,
                scope: nil,
                title: "Recents"
            ),
            over: fixture.pane.resultsTarget(inNewTab: false)
        )
        #expect(fixture.pane.isResultsListing)
        let results = fixture.pane.tabs[0]

        fixture.pane.revealLinkTarget(fixture.file("b/target.md"))
        try await fixture.settled(on: fixture.folder("b"))

        #expect(fixture.pane.tabs.count == 2)
        #expect(fixture.pane.tabs[0] === results)
        #expect(fixture.pane.activeTabIndex == 1)
        #expect(fixture.pane.quickViewSourceLocation == fixture.file("b/target.md"))
    }
}
