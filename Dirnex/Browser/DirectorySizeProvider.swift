import DirnexCore
import Foundation

/// How a scan counts bytes, carrying whatever it needs to do it (PLAN.md §M6 "optional
/// .gitignore-aware folder sizes").
///
/// An enum rather than a `scope` flag plus an optional snapshot, so "git-aware sizing with no idea
/// what is ignored" — which would silently count everything while labelling the answer filtered — is
/// not a state anyone can construct.
enum DirectorySizeRule {
    /// Every byte beneath the folder: Finder's answer, and Space-on-dir's since §M1.
    case everything
    /// Git's ignores and `.git` pruned, per the snapshot the status column is already painted from.
    case gitAware(GitStatusSnapshot)

    /// How totals under this rule are keyed in the cache — the two are never interchangeable.
    var scope: DirectorySizeScope {
        switch self {
        case .everything: .all
        case .gitAware: .gitAware
        }
    }

    /// The walk's prune predicate. `@Sendable` because it crosses onto a background walk; the
    /// snapshot it captures is a `Sendable` value type, so the walk holds a copy of the rules rather
    /// than a reference to the provider that produced them.
    var exclude: @Sendable (VFSPath) -> Bool {
        switch self {
        case .everything: { _ in false }
        case let .gitAware(snapshot): { snapshot.isExcludedFromSize($0) }
        }
    }
}

/// The app's live source of recursive directory totals: it walks directories off the main thread,
/// banks every total in a `DirnexCore.DirectorySizeCache`, and publishes batches for the panes to
/// render (PLAN.md §M6 "Size visualization mode: … computed async, cached").
///
/// The non-hermetic half — the walks, the queue, the clock — lives here, the way `GitStatusProvider`
/// owns its subprocess and `FinderTagProvider` its `getxattr` loop; everything about what the bytes
/// *mean* stays in the tested core (`SizeVisualization`, `DirectorySizeCache`). Shared, not per-pane,
/// because the unit of caching is **one directory's total**: two panes browsing the same tree ask the
/// same question and must not walk it twice.
///
/// **Why the walks run concurrently, against pass 9's plan.** Pass 9 specified a serialized queue.
/// Measured on this machine against the real `~` (68 children, hidden shown), serialization was not
/// costing throughput so much as burying the answer: `Movies` is 79 % of home — the single row the
/// whole chart is about — and it landed at **35.7 s of a 35.7 s scan**, dead last, purely because
/// display order is alphabetical and `Library` (17.0 s) and `Dev` (10.7 s) queue ahead of it. Movies
/// itself walks in 0.03 s. Widening the queue fixes exactly that:
///
///     in flight    total      t(Movies)
///     1 (pass 9)   35.7 s     35.7 s
///     4            17.9 s      3.4 s
///     8            16.3 s      1.8 s
///     16           15.7 s      0.3 s
///
/// Total plateaus around 15.7 s (that is `Library` alone — one walk, and nothing here can split it),
/// so the width is not bought for throughput. It is bought so the chart is *right* within a second
/// or two instead of re-scaling 8x at the very end when Movies finally lands.
///
/// **What bounds the width.** `DirectorySizer.size` is synchronous and blocking, so each walk in
/// flight parks a cooperative-pool thread, and Swift's pool does not over-commit. Measured, the fear
/// was mostly unfounded — an interactive listing's worst case stayed at 2.9 ms at width 8 (baseline
/// max 3.5 ms) against M1's 150 ms budget, and only width 16, which is this machine's entire core
/// count, perturbed it at all (12.9 ms). So the width is half the machine: enough to unbury the
/// answer, never enough to hand the whole pool to background walks.
@MainActor
final class DirectorySizeProvider {
    static let shared = DirectorySizeProvider()

    /// Posted when totals for a directory's children land, so every pane showing it re-seeds. The
    /// directory rides in `userInfo` under `directoryKey`; panes ignore directories they aren't
    /// showing.
    static let didChangeNotification = Notification.Name("Dirnex.directorySizesDidChange")
    static let directoryKey = "directory"
    /// The totals that just landed (`[child: bytes]`), and the scope they were counted under.
    ///
    /// **The results ride in the notification rather than being left in the cache for the pane to
    /// re-read, because between a walk landing and its publish the cache can be emptied underneath
    /// them.** Any pane's FSEvents watcher invalidates every total on its directory's root-to-leaf
    /// line, and a pane sitting on `~` therefore wipes *everything*: measured live, the other pane
    /// on the home directory produced **546 invalidations in two minutes**, roughly one every 150 ms,
    /// which is faster than a scan can publish. Announcing "something changed, go look" lost five of
    /// nine freshly-walked totals that way, and no later event re-delivered them — the folders simply
    /// stayed blank. Carrying the payload makes a computed total impossible to lose in transit.
    ///
    /// Absent on the invalidation publish, which genuinely has nothing to hand over.
    static let totalsKey = "totals"
    static let scopeKey = "scope"
    /// Set on the one publish that means "the totals you are showing answer the wrong question":
    /// the repository's ignore rules moved, so every git-aware number is not stale but *invalid*.
    /// Panes drop what they are holding rather than merely re-seeding — the distinction
    /// `DirectoryModel.clearDirectorySizes` documents.
    static let rulesChangedKey = "rulesChanged"

    /// Walks in flight at once — half the machine's logical cores (see the type's note). Clamped so
    /// a 4-core Mac still overlaps a little and a future 32-core one does not spawn 16 blocking
    /// walks for a folder nobody is looking at any more.
    private let width = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))

    /// How long results bank before a publish. Every publish costs each showing pane one
    /// `setDirectorySizes` and one re-render, so this is what keeps a 68-directory scan from
    /// becoming 68 re-sorts: at width 8 totals land in bursts, and coalescing them into ~10
    /// publishes a second makes the cost independent of how many rows the directory has.
    private let publishInterval: Duration = .milliseconds(100)

    /// Every total this session has learned, outliving the panes that asked for it. This is the
    /// authority-free latency optimization the core documents: seeding from it makes bars appear
    /// with the folder, and a re-walk corrects them.
    private var cache = DirectorySizeCache()

    /// Directories with a scan requested, and the children each still owes a walk. Keyed by the
    /// *displayed* directory **and scope** rather than by pane, so two panes on one folder coalesce
    /// — while one pane sizing it git-aware and another sizing it whole stay two jobs producing two
    /// answers, which is what they are.
    private var queue: [DirectorySizeKey: Scan] = [:]
    /// Requested directories, **most recently requested last** — the order `nextWork` drains in
    /// reverse. Newest-first is the whole point: navigating to a new folder must not wait behind the
    /// queue of one the user has already left.
    private var order: [DirectorySizeKey] = []
    /// The running drain loop, or `nil` when idle. Cancelling it cancels every walk in flight, which
    /// is why the walks go through `DirectoryLoader.cancellableSize`.
    private var drain: Task<Void, Never>?
    /// Children with a walk in flight right now.
    ///
    /// **This is what makes `requestScan` safe to call on every render**, which the pane does — it
    /// re-derives its pending list from the projection each pass. A child being walked has no total
    /// yet, so it is still "pending" from the pane's side, and without this set every publish (ten a
    /// second while a scan streams) would re-queue the whole in-flight batch and walk each of them
    /// again, several times over, against the same disk.
    ///
    /// Keyed by scope as well, or the same folder's git-aware total could never be requested while
    /// its unfiltered one was being walked — the request would be swallowed as a duplicate and the
    /// row would sit without a bar until something else disturbed it.
    private var inFlight: Set<DirectorySizeKey> = []
    /// Totals banked since the last publish, grouped by the directory they belong to and the scope
    /// they were counted under — the payload described on `totalsKey`, and the reason a landing can
    /// no longer be lost to an invalidation arriving before the publish does.
    private var landed: [DirectorySizeKey: [VFSPath: Int64]] = [:]
    private var publish: Task<Void, Never>?
    /// The ignored set each repository had when its git-aware totals were last walked — the basis
    /// `gitStatusDidChange` compares against. Bounded by `GitStatusProvider`'s own 8-snapshot cache
    /// in practice, since only repositories it is tracking ever appear here.
    private var ignoredPaths: [VFSPath: Set<String>] = [:]

    private init() {
        // Ignore rules changing is the one thing that invalidates a git-aware total without a byte
        // moving on disk, so FSEvents — which drives every other invalidation here — cannot see it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gitStatusDidChange),
            name: GitStatusProvider.didChangeNotification,
            object: nil
        )
    }

    private struct Scan {
        /// The backend to walk with — carried per request because the provider is shared while
        /// backends are the panes'. `VFSBackend` is `Sendable`, so it crosses to the walk freely.
        let backend: any VFSBackend
        /// How this scan counts bytes, carried for the same reason as the backend: the rule is the
        /// pane's (it holds the repository snapshot), the queue is everyone's.
        let rule: DirectorySizeRule
        /// Children still owing a walk, in display order.
        var children: [VFSPath]
    }

    // MARK: - Reading (the render path)

    /// Every total already known among `paths` — what a pane seeds itself from on arrival, in one
    /// bulk `Panel.setDirectorySizes` rather than one call per row. Pass 9 measured why that matters:
    /// seeding one-by-one re-sorts the listing per call and costs 2.5 s at 3,000 rows, which would
    /// make the cache slower than having no cache at the one job it has.
    func cachedSizes(for paths: [VFSPath], rule: DirectorySizeRule) -> [VFSPath: Int64] {
        var known: [VFSPath: Int64] = [:]
        for path in paths {
            guard let bytes = cache.size(for: path, scope: rule.scope) else { continue }
            known[path] = bytes
        }
        return known
    }

    // MARK: - Scanning

    /// Walk everything in `children` that isn't already known, on `directory`'s behalf.
    ///
    /// Re-requesting a directory **replaces** its outstanding work rather than appending: the caller
    /// passes what is pending *now*, so a re-list that removed a folder must not leave it queued.
    /// Already-cached children are dropped here rather than in the pane, so a revisit costs nothing.
    func requestScan(
        for directory: VFSPath,
        children: [VFSPath],
        backend: any VFSBackend,
        rule: DirectorySizeRule
    ) {
        let scope = rule.scope
        let unknown = children.filter { child in
            cache.size(for: child, scope: scope) == nil
                && !inFlight.contains(DirectorySizeKey(path: child, scope: scope))
        }
        guard !unknown.isEmpty else {
            // Nothing to do — but the directory may have had work a moment ago (everything just
            // landed, or the cache was seeded), so clear it rather than leave a spent entry behind.
            cancelScan(for: directory)
            return
        }
        let key = DirectorySizeKey(path: directory, scope: scope)
        queue[key] = Scan(backend: backend, rule: rule, children: unknown)
        order.removeAll { $0 == key }
        order.append(key)
        startDraining()
    }

    /// Drop `directory`'s outstanding work — the pane navigated away, switched tabs, or left the
    /// mode. Walks already in flight are left to finish: their answer is still true, the cache is
    /// keyed by path rather than by who asked, and abandoning a walk that is nearly done only means
    /// paying for it again on the way back. The mid-walk cancellation that
    /// `DirectoryLoader.cancellableSize` provides is for the whole queue going quiet, below.
    ///
    /// Across **both** scopes, deliberately: the callers are "this pane navigated away" and "this
    /// pane left the mode", and neither wants the folder's other total either. Taking a scope here
    /// would only create a way to forget to cancel the one the pane just stopped using.
    func cancelScan(for directory: VFSPath) {
        for scope in DirectorySizeScope.allCases {
            queue.removeValue(forKey: DirectorySizeKey(path: directory, scope: scope))
        }
        order.removeAll { $0.path == directory }
    }

    /// Stop everything, mid-walk. The one caller is the last tab anywhere leaving the mode: with no
    /// queue left, an in-flight `/System` walk has nowhere to put its answer and no reason to keep a
    /// blocking thread parked.
    func cancelAllScans() {
        queue.removeAll()
        order.removeAll()
        drain?.cancel()
        drain = nil
    }

    /// One walk to perform: which child, on whose behalf, with what, counted how.
    private struct Work {
        let directory: VFSPath
        let child: VFSPath
        let backend: any VFSBackend
        let rule: DirectorySizeRule
    }

    /// The next child to walk: from the **most recently requested** directory that still owes work.
    private func nextWork() -> Work? {
        while let key = order.last {
            guard var scan = queue[key], !scan.children.isEmpty else {
                // Spent or cancelled — drop it and look at the next-newest.
                queue.removeValue(forKey: key)
                order.removeLast()
                continue
            }
            let child = scan.children.removeFirst()
            queue[key] = scan
            return Work(
                directory: key.path,
                child: child,
                backend: scan.backend,
                rule: scan.rule
            )
        }
        return nil
    }

    private func startDraining() {
        guard drain == nil else { return }
        drain = Task { [weak self] in
            await self?.drainQueue()
            self?.drain = nil
        }
    }

    /// Walk the queue, `width` at a time, until it runs dry.
    ///
    /// A child task, not a detached one, so cancelling `drain` reaches the walks themselves. The
    /// loop re-reads `nextWork` after every landing rather than snapshotting the queue up front —
    /// that is what lets a directory requested *while the scan runs* (the user navigated) jump the
    /// rest, and what lets `cancelScan` take effect immediately.
    private func drainQueue() async {
        await withTaskGroup(of: Landing.self) { group in
            var running = 0
            while true {
                while running < width, let work = nextWork() {
                    let scope = work.rule.scope
                    inFlight.insert(DirectorySizeKey(path: work.child, scope: scope))
                    let exclude = work.rule.exclude
                    group.addTask(priority: .utility) {
                        let bytes = await DirectoryLoader.cancellableSize(
                            work.backend,
                            of: work.child,
                            excluding: exclude
                        )
                        return Landing(
                            directory: work.directory,
                            child: work.child,
                            scope: scope,
                            bytes: bytes
                        )
                    }
                    running += 1
                }
                guard running > 0, let landing = await group.next() else { break }
                running -= 1
                inFlight.remove(DirectorySizeKey(path: landing.child, scope: landing.scope))
                guard !Task.isCancelled else { break }
                // A failed or cancelled walk banks nothing: an absent total re-walks next visit,
                // where a wrong one would be believed. The core's cache is a latency optimization
                // and never an authority — this is the boundary that keeps it honest.
                guard let bytes = landing.bytes else { continue }
                cache.store(bytes, for: landing.child, scope: landing.scope)
                let key = DirectorySizeKey(path: landing.directory, scope: landing.scope)
                landed[key, default: [:]][landing.child] = bytes
                schedulePublish()
            }
            group.cancelAll()
            // Whatever `cancelAll` just abandoned is no longer in flight; leaving it in the set
            // would make those children permanently unrequestable — a folder that never gets a bar
            // again for the rest of the session.
            inFlight.removeAll()
        }
    }

    private struct Landing: Sendable {
        let directory: VFSPath
        let child: VFSPath
        let scope: DirectorySizeScope
        let bytes: Int64?
    }

    // MARK: - Publishing

    /// Announce the directories that gained totals, at most once per `publishInterval`. The trailing
    /// edge is the useful one here (unlike the providers', which debounce a *request*): results
    /// arrive continuously and the panes want them continuously, just not 68 times.
    private func schedulePublish() {
        guard publish == nil else { return }
        let interval = publishInterval
        publish = Task { [weak self] in
            try? await Task.sleep(for: interval)
            self?.publish = nil
            self?.flush()
        }
    }

    private func flush() {
        let batches = landed
        landed = [:]
        for (key, totals) in batches {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: [
                    Self.directoryKey: key.path,
                    Self.scopeKey: key.scope,
                    Self.totalsKey: totals
                ]
            )
        }
    }

    // MARK: - Invalidation

    /// Forget every total a change under `path` could have altered, and tell the panes.
    ///
    /// The rule itself is the core's (`DirectorySizeCache.invalidate(under:)`): the path, its
    /// descendants *and* its ancestors — everything on one root-to-leaf line — because an FSEvents
    /// ping proves only "something under here changed" (`DirectoryWatcher` discards the event paths)
    /// and an ancestor's total sums whatever it was. Siblings survive, which is the whole value.
    ///
    /// The publish is unconditional and immediate rather than batched: this is the path where a
    /// *stale* number is on screen right now, and it is rare (a real filesystem change), where the
    /// batched path is common (a scan landing).
    func invalidate(under path: VFSPath) {
        cache.invalidate(under: path)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.directoryKey: path]
        )
    }

    /// A repository was re-read. Drop its git-aware totals **only if what it ignores actually
    /// changed**, and tell the panes to stop showing the ones they hold.
    ///
    /// The conditional is the whole method. `GitStatusProvider` republishes on every debounced read
    /// — the pane it feeds does its own equality check — so in a repository under a build this fires
    /// continuously. Invalidating on each would re-walk every sized folder several times a second,
    /// against the same disk the build is using. `GitStatusSnapshot.ignoredPaths` moves only when
    /// the rules do (a `.gitignore` edit, a branch switch, a `git add` of an ignored file), which is
    /// exactly when a git-aware total stops being true.
    ///
    /// A repository whose status could not be read caches no snapshot; its remembered set is dropped
    /// so the next successful read is treated as a first look rather than compared against a basis
    /// that no longer describes anything.
    @objc private func gitStatusDidChange(_ notification: Notification) {
        guard let root = notification.userInfo?[GitStatusProvider.repositoryRootKey] as? VFSPath
        else { return }
        guard let snapshot = GitStatusProvider.shared.cachedSnapshot(for: root) else {
            ignoredPaths.removeValue(forKey: root)
            return
        }
        let ignored = snapshot.ignoredPaths
        let previous = ignoredPaths.updateValue(ignored, forKey: root)
        // A first look establishes the basis without invalidating: nothing has been walked under
        // rules we never saw, so there is nothing to be wrong.
        guard let previous, previous != ignored else { return }
        cache.invalidateGitAware(under: root)
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.directoryKey: root, Self.rulesChangedKey: true]
        )
    }
}
