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
///
/// **That observable answers every repaint, including the ones nobody here caused**, and until
/// 2026-08-22 this suite failed about **one full run in four** while passing alone every time —
/// which reads as machine load and was not. Logging every `renderRefresh` with its call stack found
/// three separate races, none of them in the product:
///
/// 1. **The suite's own first step.** `pane(at:)` waited for `numberOfRows > 0`, which an *empty*
///    pane satisfies — the `..` row is drawn and selected before any listing lands — so the
///    navigation's own `reloadEverything` arrived 130 ms *inside* `quiesce`.
/// 2. **What a refresh pulls.** Both refresh paths end by waking the git, tag and sync consumers
///    unconditionally, and the sync provider's first scan publishes into a shared cache *after* the
///    listing has. The measured refresh collected it and repainted — the pane doing exactly its job,
///    650 ms into a window that was supposed to be quiet.
/// 3. **Other suites.** Of the **58–66** repaints these four fixture panes took in one run, every
///    single one came from another suite writing a preference — `applyPalette`, `applyRowDensity`,
///    `applyFileColorRules` — through `AppPreferences.shared` and `NotificationCenter`, which every
///    live pane in the test host observes.
///
/// (1) and (2) are what actually failed; (3) is a coin toss against a 2 s window, and removing it is
/// belt and braces (measured: with the deafening alone reverted, six full runs stayed green). All
/// three are answered in the fixture rather than in the product, because the product is right — a
/// preference change *should* repaint every pane, and so should a first sync snapshot. What none of
/// them may do is land inside a measurement of the listing path.
///
/// A **fourth** was left, and unlike those three it was the product's: the providers' shared
/// `DirectoryScanCache` is an LRU of eight across every pane and tab, so a directory still on screen
/// aged out whenever eight others were scanned, and the pull that followed read the miss as an
/// answer and blanked the pane's badges. Same probe, 2026-08-27 — a fixture's own directory evicted
/// mid-test for `/Users/oleg`, for `/iCloud Drive`, for another suite's tree fixture, and once for a
/// sibling pane in this very suite. It is answered in the product (a miss is not an answer) and
/// pinned by `evictionFromTheSharedScanCacheDoesNotRepaint` below.
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

    /// What ``fixture()`` puts in the pane's own directory: `alpha.txt`, `beta.txt` and `sub/`.
    private static let fixtureEntryCount = 3

    /// A loaded, **deafened** pane that has finished listing its own directory.
    ///
    /// `loadViewIfNeeded()` for the reason `RenameReachTests` records — an unloaded pane's table has
    /// no columns and no rows, so every assertion here would read the same whatever the code did.
    ///
    /// `removeObserver` immediately after it, which takes the preference storm above out of the
    /// window: every one of the pane's observers is selector-based on the default center (the house
    /// rule docs/NOTES.md states for a `nonisolated deinit`) and all of them are installed once, in
    /// `viewDidLoad` and `configureTable`, so one call takes the lot and nothing re-registers. What
    /// stays is everything this suite measures — the FSEvents watcher is an `FSEventStream`
    /// callback, not a notification, and `refreshTree()` is called here by name.
    ///
    /// It is **insurance rather than the fix**, and the control says so: with it removed and the two
    /// repairs below kept, six full runs were still green. A storm render is a coin toss against a
    /// 2 s window rather than a certainty — which is exactly the kind of coupling worth removing
    /// while the reason for it is known and written down, since nothing about it would announce
    /// itself the day another suite's timing shifts.
    ///
    /// The wait is on the **entries**, not on the row count, and the difference is not cosmetic: a
    /// pane whose listing has not landed still draws the `..` row and still selects it, so
    /// `numberOfRows > 0 && selectedRow >= 0` was satisfied by an *empty* pane — measured, the
    /// navigation's own `reloadEverything` then landed 130 ms **inside** `quiesce`. The suite's own
    /// first step was a race.
    private static func pane(at root: URL, tree: Bool) async throws -> PanelViewController {
        let pane = PanelViewController(
            backend: CompositeBackend(local: LocalBackend()),
            restoration: nil,
            defaultPath: .local(root.path),
            restorationKey: nil
        )
        pane.loadViewIfNeeded()
        NotificationCenter.default.removeObserver(pane)
        if tree {
            pane.viewMode = .tree
            pane.applyViewMode()
        }
        let listed = await settle {
            pane.panel.displayedEntries.count == fixtureEntryCount && pane.tableView.selectedRow >= 0
        }
        #expect(listed, "the pane never listed its own directory")
        await quiesce(pane)
        return pane
    }

    /// Wait until the pane stops repainting of its own accord, leaving the table deselected and
    /// ready to be measured — **pulling** what a refresh would pull rather than only waiting.
    ///
    /// That last part is what the original was missing, and it is the half that carried the flake.
    /// Some of what a refresh re-derives is pulled rather than pushed: both refresh paths end by
    /// waking the git, tag and sync consumers *unconditionally* — deliberately, since none of their
    /// states is derivable from a listing (`directoryDidChange` names exactly these three) — and
    /// `updateSyncStatus` reads a shared provider cache whose first scan lands **after** the listing
    /// has. So the first refresh after that legitimately repaints, and it was the *measured* one:
    /// every fixture pane took an `applySyncSnapshot` render 650 ms into its measurement window
    /// (measured 2026-08-22, by logging every `renderRefresh` with its call stack).
    ///
    /// Calling the three funnels directly rather than driving a whole refresh is deliberate: the
    /// mechanism under test must not be what prepares the measurement, and `refreshCurrentDirectory`
    /// in list mode is an *explicit* re-list with no unchanged-guard at all, so driving that would
    /// never settle. Each of the three is a no-op once its snapshot has landed, so this converges on
    /// the round after the last one publishes.
    ///
    /// **The round has to outlast the scan's debounce, and 300 ms starves it exactly.** Every
    /// provider here reads through a `DirectoryScanCache`, whose `requestRefresh` runs the *first*
    /// look at once and debounces the rest by 300 ms — cancelling the pending timer each time. A
    /// pull every 300 ms therefore keeps pushing the scan out in front of itself: measured, the
    /// snapshot then landed 460 ms **after** quiesce gave up, inside the measurement window, and the
    /// two tree tests failed on it every run. At 750 ms the scan fires inside the round and the next
    /// pull collects it. `maximumStaleness` (2 s) is the other end of the same rule — a pull that
    /// arrives later than that runs immediately.
    private static func quiesce(_ pane: PanelViewController) async {
        await waitForProviderScans(pane)
        for _ in 0..<15 {
            pane.tableView.deselectAll(nil)
            pullRefreshTail(pane)
            try? await Task.sleep(for: .milliseconds(750))
            // **Again, after the wait**, and this is the line the whole helper turns on: a quiet
            // round proves nothing if the round's only pull happened before the scan it was waiting
            // for had published. Measured that way round, quiesce returned after one silent round
            // and the *measured* refresh collected the snapshot 400 ms later — 2 tests failing every
            // run. Pulling again at the end is what makes "quiet" mean "and nothing was left to
            // collect": if this one repaints, the round was not quiet and the loop goes again.
            pullRefreshTail(pane)
            if pane.tableView.selectedRow == -1 { return }
        }
        Issue.record("the pane never stopped repainting an untouched directory")
    }

    /// What both refresh paths do after the listing, unconditionally and by design — none of these
    /// three states is derivable from a listing, so each is woken on every event and each carries its
    /// own no-op-when-unchanged guard (`directoryDidChange` names exactly these).
    private static func pullRefreshTail(_ pane: PanelViewController) {
        pane.updateGitStatus()
        pane.updateTagStatus()
        pane.updateSyncStatus()
    }

    /// Wait until the providers this pane would pull from have actually published for its directory,
    /// so the loop above collects a snapshot rather than racing one.
    ///
    /// Waiting on the **provider's own cache** rather than on a duration is what makes this exact:
    /// the loop's rounds only narrow the window a late publish can land in, and the residual was
    /// visible — 1 run in 6, always the two tree tests together, and always in a run that finished
    /// *faster* than a green one, which is what a `quiesce` that settled in a single round looks
    /// like from outside.
    ///
    /// Asked of the pane, not of the preference: `areTagsVisible` and `isSyncStatusVisible` are the
    /// same gates `updateTagStatus` and `updateSyncStatus` read, so a pane that will never pull
    /// waits for nothing — which matters because both are user settings this suite must not touch,
    /// and the test host runs against whatever the developer has set. Git has no wait: a temp
    /// directory is not a repository, so its snapshot stays `nil` and `applyGitSnapshot` is a no-op
    /// however late it arrives.
    private static func waitForProviderScans(_ pane: PanelViewController) async {
        let directory = pane.panel.path
        if pane.isSyncStatusVisible {
            _ = await settle { CloudSyncStatusProvider.shared.cachedSnapshot(for: directory) != nil }
        }
        if pane.areTagsVisible {
            _ = await settle { FinderTagProvider.shared.cachedSnapshot(for: directory) != nil }
        }
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

    // MARK: - The shared scan cache

    /// A pane must not repaint because the **shared** provider cache evicted the directory it is
    /// showing.
    ///
    /// `DirectoryScanCache` holds eight directories for every pane and tab in the process and evicts
    /// by store recency, which knows nothing about what is on screen — so a directory still being
    /// drawn ages out as soon as eight others are scanned. `updateSyncStatus` and `updateTagStatus`
    /// then read a **miss**, and until 2026-08-27 applied it: the tab's snapshot went to `nil`, every
    /// badge and dot in the pane was erased, and `renderRefresh` reloaded the table — twice, because
    /// the scan those same calls had just started published a moment later and drew them back.
    ///
    /// In the app that is a visible flicker of every badge on any Mac with five tabs open, since two
    /// panes of four is already the whole cache. Here it was the fourth race, and the one that
    /// outlived the three the fixture above answers: it repainted a pane inside `hold()` and failed
    /// `treeRefreshWithADeepChange` about one full run in six.
    ///
    /// **Both directions are asserted, and the first is the narrowness control.** A cache *hit* must
    /// still be adopted — the pane holds a snapshot before the eviction because `quiesce`'s pulls
    /// took one — or "ignore the cache" would pass the second half by never reading it at all.
    ///
    /// Exercises whichever badge the developer has switched on, the same gate `waitForProviderScans`
    /// respects and for the same reason: the test host inherits their own preferences, and flipping
    /// one here would post the notification that repaints every live pane in the process (race 3).
    /// A default install has both on, and this machine's run of the reverted fix failed here.
    @Test("a shared-cache eviction of the directory on screen does not reload the table")
    func evictionFromTheSharedScanCacheDoesNotRepaint() async throws {
        let root = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let pane = try await Self.pane(at: root, tree: false)
        let directory = pane.panel.path

        if pane.isSyncStatusVisible {
            #expect(pane.syncSnapshot != nil, "the pane never adopted a cached sync snapshot")
        }
        if pane.areTagsVisible {
            #expect(pane.tagSnapshot != nil, "the pane never adopted a cached tag snapshot")
        }

        let aged = try await Self.ageOutOfTheScanCaches(directory, pane: pane)
        #expect(aged, "the fixture's directory never aged out of the shared caches")

        pane.tableView.deselectAll(nil)
        Self.pullRefreshTail(pane)
        await Self.hold()

        #expect(
            pane.tableView.selectedRow == -1,
            "a shared-cache eviction repainted a pane whose directory nothing had happened to"
        )
        if pane.isSyncStatusVisible {
            #expect(pane.syncSnapshot != nil, "the eviction erased the pane's sync badges")
        }
        if pane.areTagsVisible {
            #expect(pane.tagSnapshot != nil, "the eviction erased the pane's tag dots")
        }
    }

    /// Push enough other directories through the shared caches to evict `directory` — what a fifth
    /// open tab does to the app, arranged on purpose.
    ///
    /// Comfortably more than the cache's own limit, because this is not the only thing filling it:
    /// every other suite's panes are storing their own keys into it at the same time, and each of
    /// those pushes ours one place further along rather than holding it still. Real directories, so
    /// what lands in the cache is what a real visit would put there.
    ///
    /// Reports whether the eviction actually happened for whichever provider the pane will pull
    /// from, so the assertion above cannot pass against a cache that never dropped anything.
    private static func ageOutOfTheScanCaches(
        _ directory: VFSPath,
        pane: PanelViewController
    ) async throws -> Bool {
        let ballast = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dirnex-passive-ballast-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: ballast) }
        for index in 0..<24 {
            let child = ballast.appendingPathComponent("\(index)")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            let path = VFSPath.local(child.path)
            CloudSyncStatusProvider.shared.requestRefresh(for: path, entries: [])
            FinderTagProvider.shared.requestRefresh(for: path, entries: [])
        }
        return await settle {
            let syncGone = !pane.isSyncStatusVisible
                || CloudSyncStatusProvider.shared.cachedSnapshot(for: directory) == nil
            let tagsGone = !pane.areTagsVisible
                || FinderTagProvider.shared.cachedSnapshot(for: directory) == nil
            return syncGone && tagsGone
        }
    }
}
