import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// What a pane does with an FSEvents ping that means nothing to it.
///
/// `DirectoryWatcher`'s stream is **recursive** and discards the event's paths, so a ping proves only
/// "something under here changed" — and under a home directory that is almost never a row on screen.
/// Measured 2026-08-21 with a pane sitting on `/Users/oleg` and nothing touched: ~5 events a second,
/// every one of them from `~/Library` (Chrome's cache, Spotlight's index, a sync client's metrics),
/// and **152 full `reloadData` calls in 31 idle seconds** over 27 rows that never changed.
///
/// That is not merely wasted work: the user sees it. AppKit's expansion tooltip — what floats a name
/// too long for its column (`FileCellView`, `ExpandingLabel`) — is torn down with the cell view a
/// reload discards, and at five reloads a second it can no longer survive its own appearance delay.
/// Reported as a tooltip that "blinks" on any long folder in the home directory; A/B'd live on the
/// same pointer position, the panel was present in 3/3 samples with the guard in and absent in 4/4
/// without it.
///
/// The rule the fix restores is the one the *other* three consumers of this event already kept —
/// `applyGitSnapshot`, `applyTagSnapshot` and `applySyncSnapshot` each say "a no-op when nothing
/// changed, so the FSEvents-driven republish of an untouched directory costs no reload". The listing
/// was the one that did not, and it is the consumer that repaints every row.
///
/// **The observable is the table's selection**, because `NSTableView` offers no reload count:
/// `renderRefresh` ends in `syncCursorToTable`, so a table deselected by hand comes back selected if
/// and only if the pane re-rendered. `reconcileCursorFromTable` returns early on an empty selection,
/// so deselecting does not disturb the model cursor it would otherwise be read from.
@MainActor
@Suite("Passive refresh")
struct PanelPassiveRefreshTests {
    // MARK: - Fixture

    /// A directory holding two files and an **unexpanded** `sub/deep/`, which is where a change that
    /// must not reach the pane is made: creating a file inside `deep` moves only `deep`'s mtime, so
    /// the root's own entries are byte-identical afterwards while FSEvents still fires.
    private static func fixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirnex-passive-\(UUID().uuidString)")
        let deep = root.appendingPathComponent("sub/deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for name in ["alpha.txt", "beta.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    /// A loaded pane that has finished listing its own directory.
    ///
    /// `loadViewIfNeeded()` for the reason `RenameReachTests` records — an unloaded pane's table has
    /// no columns and no rows, so every assertion here would read the same whatever the code did.
    private static func pane(at root: URL, tree: Bool) async throws -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local(root.path),
            restorationKey: nil
        )
        pane.loadViewIfNeeded()
        if tree {
            pane.viewMode = .tree
            pane.applyViewMode()
        }
        let listed = await settle { pane.tableView.numberOfRows > 0 && pane.tableView.selectedRow >= 0 }
        #expect(listed, "the pane never listed its own directory")
        await quiesce(pane)
        return pane
    }

    /// Wait until the pane stops repainting of its own accord, leaving the table deselected.
    ///
    /// A freshly loaded pane has three more renders still to come, and none of them is the bug: the
    /// git, tag and sync consumers each land their *first* snapshot asynchronously, and going from
    /// "no snapshot" to one is a real change by their own guards. Measuring before they settle
    /// reads their arrival as the listing having repainted. That it settles at all is itself an
    /// assertion — a temp directory nothing writes to has nothing left to report.
    private static func quiesce(_ pane: PanelViewController) async {
        for _ in 0..<25 {
            pane.tableView.deselectAll(nil)
            try? await Task.sleep(for: .milliseconds(300))
            if pane.tableView.selectedRow == -1 { return }
        }
        Issue.record("the pane never stopped repainting an untouched directory")
    }

    /// Poll rather than spin the run loop: these refreshes land through a `Task`, and a run-loop spin
    /// drives layout without ever letting the main actor suspend, so the result simply never arrives
    /// (docs/NOTES.md ▸ Testing). Generous, because a satisfied predicate returns on the next poll —
    /// the budget only sets how much scheduling delay is absorbed before the code is blamed.
    private static func settle(within seconds: Double = 10, until isDone: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if isDone() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return isDone()
    }

    /// Wait a delay **out** to prove nothing happens. Its length is the claim, so it is fixed rather
    /// than scaled for a slow machine (docs/NOTES.md ▸ Testing) — and it is many times the 0.15 s
    /// FSEvents latency the watcher is built with.
    private static func hold(seconds: Double = 2) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: - Tree mode (150 of the 152 measured reloads)

    @Test("a tree refresh that finds nothing changed does not reload the table")
    func treeRefreshWithNothingChanged() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try await Self.pane(at: root, tree: true)

        pane.refreshTree()
        await Self.hold()

        #expect(
            pane.tableView.selectedRow == -1,
            "the pane re-rendered for a refresh that found the same entries it already had"
        )
    }

    @Test("nor does a change below an unexpanded folder, which is what FSEvents mostly reports")
    func treeRefreshWithADeepChange() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try await Self.pane(at: root, tree: true)

        try Data("x".utf8).write(to: root.appendingPathComponent("sub/deep/churn.txt"))
        pane.refreshTree()
        await Self.hold()

        #expect(
            pane.tableView.selectedRow == -1,
            "a change two levels below the deepest row re-rendered the pane"
        )
    }

    /// The narrowness control, and the one that matters more: without it "never reload" would pass.
    @Test("a real change still reaches the tree")
    func treeRefreshWithARealChange() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try await Self.pane(at: root, tree: true)
        let before = pane.tableView.numberOfRows

        try Data("x".utf8).write(to: root.appendingPathComponent("gamma.txt"))
        pane.refreshTree()

        let grew = await Self.settle { pane.tableView.numberOfRows == before + 1 }
        #expect(grew, "a file created in the pane's own directory never appeared")
        #expect(pane.tableView.selectedRow >= 0, "the pane never re-applied its cursor")
    }

    // MARK: - List mode, through the real watcher

    /// Drives FSEvents itself rather than a function call, which is what proves the *wiring*: the
    /// guard lives past `startWatching`, the recursive stream and a real re-list.
    ///
    /// The positive control runs **first and in the same test**, because a watcher that is not armed
    /// at all would pass the negative half vacuously — the failure mode this test exists to avoid.
    @Test("the list-mode watcher ignores an event that leaves its directory identical")
    func listWatcherIgnoresADeepChange() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try await Self.pane(at: root, tree: false)
        let before = pane.tableView.numberOfRows

        // Positive control: the stream is live and a real change does arrive.
        try Data("x".utf8).write(to: root.appendingPathComponent("gamma.txt"))
        let grew = await Self.settle { pane.tableView.numberOfRows == before + 1 }
        #expect(grew, "the watcher never delivered a change to the pane's own directory")

        // The claim: the same stream fires for this, and the pane must not repaint.
        await Self.quiesce(pane)
        try Data("x".utf8).write(to: root.appendingPathComponent("sub/deep/churn.txt"))
        await Self.hold()

        #expect(
            pane.tableView.selectedRow == -1,
            "an event about a file two levels down re-rendered the pane"
        )
    }
}
