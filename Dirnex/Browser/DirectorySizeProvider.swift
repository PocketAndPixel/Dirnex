import DirnexCore
import Foundation

/// How a scan counts bytes, carrying whatever it needs to do it (PLAN.md §M6 "optional
/// .gitignore-aware folder sizes").
///
/// An enum rather than a `scope` flag plus an optional snapshot, so "git-aware sizing with no idea
/// what is ignored" — which would silently count everything while labeling the answer filtered — is
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
    /// Children this publish is reporting **no total** for, because the set ran out of allowance
    /// before reaching them (`DirectorySizeBudget.forSet(ofBackend:)`). The pane draws them with the
    /// marker and tooltip Space-on-dir's own give-up already uses, rather than leaving them looking
    /// like a walk that has not landed yet — which is the one thing they are not.
    static let gaveUpKey = "gaveUp"
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
    let publishInterval: Duration = .milliseconds(100)

    /// Every total this session has learned, outliving the panes that asked for it. This is the
    /// authority-free latency optimization the core documents: seeding from it makes bars appear
    /// with the folder, and a re-walk corrects them.
    var cache = DirectorySizeCache()

    /// Directories with a scan requested, and the children each still owes a walk. Keyed by the
    /// *displayed* directory **and scope** rather than by pane, so two panes on one folder coalesce
    /// — while one pane sizing it git-aware and another sizing it whole stay two jobs producing two
    /// answers, which is what they are.
    private var queue: [DirectorySizeKey: Scan] = [:]
    /// Requested directories, **most recently requested last** — the order `nextWork` drains in
    /// reverse. Newest-first is the whole point: navigating to a new folder must not wait behind the
    /// queue of one the user has already left.
    private var order: [DirectorySizeKey] = []
    /// The running drain loop, or `nil` when idle. Canceling it cancels every walk in flight, which
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
    /// Children whose set ran out of allowance before reaching them, so they carry no total and
    /// **must not be asked for again** until something changes.
    ///
    /// It is the memory that keeps a bound from becoming a metronome. The pane re-derives its
    /// pending list from the projection on every render and a row with no total is pending forever,
    /// so without this the exhausted set would be re-queued — and re-granted — on each repaint.
    /// Cleared by `invalidate(under:)`, which is proof the folder changed, and by `cancelAllScans`,
    /// which is the mode being switched off everywhere: both are the user or the filesystem saying
    /// the question is worth asking again, where idling is not.
    var gaveUp: Set<DirectorySizeKey> = []
    /// The one bounded walk in flight and the flag that abandons it mid-walk.
    ///
    /// One, not a set, because bounded scans are deliberately serialized — see `nextWork`. That is
    /// what makes ``DirectorySizeBudget/abandonsWhenUnwatched`` expressible here at all: a task
    /// group cannot cancel one of its children, so the walk is handed a flag instead.
    private var boundedWalk: (key: DirectorySizeKey, abandon: AbandonFlag)?
    /// Totals banked since the last publish, grouped by the directory they belong to and the scope
    /// they were counted under — the payload described on `totalsKey`, and the reason a landing can
    /// no longer be lost to an invalidation arriving before the publish does.
    var landed: [DirectorySizeKey: [VFSPath: Int64]] = [:]
    /// Children this scan gave up on since the last publish, grouped like `landed` and published
    /// beside it — see `gaveUpKey`.
    var gaveUpSinceLastPublish: [DirectorySizeKey: Set<VFSPath>] = [:]
    var publish: Task<Void, Never>?
    /// The ignored set each repository had when its git-aware totals were last walked — the basis
    /// `gitStatusDidChange` compares against. Bounded by `GitStatusProvider`'s own 8-snapshot cache
    /// in practice, since only repositories it is tracking ever appear here.
    var ignoredPaths: [VFSPath: Set<String>] = [:]

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
        /// What the **whole set** may still spend, or `nil` where a walk costs nothing anybody is
        /// billed for (`DirectorySizeBudget.forSet(ofBackend:)`).
        ///
        /// One allowance for the batch, not one per child, and that is the difference between the
        /// bars being affordable on a server and not: N children each entitled to
        /// `DirectorySizeBudget.remote`'s thousand listings is N thousand billed requests for one
        /// keystroke. Decremented by what each walk reports it spent
        /// (``DirectorySizeMeasurement/requestsMade``), which is 1 for a backend that can hand over
        /// a whole subtree and one per directory for one that cannot.
        var allowance: Int?

        var isBounded: Bool { allowance != nil }
        var hasAllowanceLeft: Bool { (allowance ?? 1) > 0 }
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
            let childKey = DirectorySizeKey(path: child, scope: scope)
            return cache.size(for: child, scope: scope) == nil
                && !inFlight.contains(childKey)
                // A child a spent set already gave up on must not be re-queued. The pane re-derives
                // its pending list from the projection on **every render**, and a row with no total
                // is pending forever — so without this the allowance would be re-granted and spent
                // again on each repaint, which on a billed backend is a bill that never stops.
                // Cleared by `invalidate`, so a real change re-earns the attempt, as does the user
                // toggling the mode off and on.
                && !gaveUp.contains(childKey)
        }
        guard !unknown.isEmpty else {
            // Nothing to do — but the directory may have had work a moment ago (everything just
            // landed, or the cache was seeded), so clear it rather than leave a spent entry behind.
            //
            // **Not `cancelScan`**, which also abandons the walk in flight. For a bounded set that
            // is exactly one walk, and "nothing left to queue" is the state a re-render reaches
            // while the *last* child is still being walked — so routing this through the pane's own
            // cancellation would abandon the row the user is waiting for, on every repaint, every
            // time. One function, two intents: the pane saying it stopped looking, and the queue
            // saying it has nothing more to hand out.
            clearQueuedWork(for: directory)
            return
        }
        let key = DirectorySizeKey(path: directory, scope: scope)
        // A re-request replaces the outstanding *work* and **carries the allowance forward**, which
        // is the half that makes it a bound at all. The pane re-requests on every render — ten
        // times a second while a scan streams in — so seeding afresh each time would hand the same
        // set a new thousand listings per repaint, which is not a budget but a metronome. A fresh
        // one is seeded only when no scan for this directory is outstanding: a visit that starts
        // over may spend again, a repaint may not.
        queue[key] = Scan(
            backend: backend,
            rule: rule,
            children: unknown,
            allowance: queue[key]?.allowance
                ?? DirectorySizeBudget.forSet(ofBackend: directory.backend).directoryLimit
        )
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
        clearQueuedWork(for: directory)
        // A **bounded** walk in flight is abandoned rather than left to finish, which is the
        // opposite of the rule above for a local one and is
        // ``DirectorySizeBudget/abandonsWhenUnwatched`` reaching an individual walk. Locally nobody
        // pays for a walk nobody is waiting for and its answer is still true; remotely it is the
        // user's money and their bandwidth, spent on a number that now has no row to land in.
        //
        // This is the half `clearQueuedWork` deliberately leaves out, because only *this* caller
        // knows the pane has stopped looking.
        if let bounded = boundedWalk, bounded.key.path.isSelfOrDescendant(of: directory) {
            bounded.abandon.abandon()
        }
    }

    /// Drop `directory`'s **queued** work under both scopes, touching nothing already in flight.
    private func clearQueuedWork(for directory: VFSPath) {
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
        boundedWalk?.abandon.abandon()
        boundedWalk = nil
        // The mode is off everywhere, so the next time it is switched on is a fresh question the
        // user asked — a set that gave up gets another allowance rather than being refused for the
        // life of the session.
        gaveUp.removeAll()
        drain?.cancel()
        drain = nil
    }

    /// One walk to perform: which child, on whose behalf, with what, counted how, and how much of
    /// the set's allowance it may spend.
    private struct Work {
        let directory: VFSPath
        let child: VFSPath
        let backend: any VFSBackend
        let rule: DirectorySizeRule
        /// What is left of the whole set's allowance — this walk may spend all of it, which is safe
        /// because a bounded set runs one walk at a time (`nextWork`).
        let budget: DirectorySizeBudget
        let abandon: AbandonFlag
    }

    /// The next child to walk: from the **most recently requested** directory that still owes work.
    ///
    /// A **bounded** scan hands out one walk at a time, and stops the fill loop dead rather than
    /// skipping past itself. Two reasons, and either would be enough. The allowance is only exact
    /// if nothing else is spending it concurrently — eight walks each granted the remainder can
    /// spend eight times it — and a burst of remote listings is its own problem: a stock OpenSSH
    /// server begins **dropping** connections at ten concurrent unauthenticated ones
    /// (`MaxStartups`, docs/NOTES.md ▸ Testing), which this project has already been bitten by from
    /// its own live suites. Nothing is lost by stopping: the loop refills on every landing, and the
    /// newest scan is the one the user is looking at.
    private func nextWork() -> Work? {
        while let key = order.last {
            guard var scan = queue[key], !scan.children.isEmpty else {
                // Spent or canceled — drop it and look at the next-newest.
                queue.removeValue(forKey: key)
                order.removeLast()
                continue
            }
            guard scan.hasAllowanceLeft else {
                // The set spent everything it had. Whatever it never reached is *given up* rather
                // than merely unwalked, so the pane can say so and nothing re-queues it.
                retire(scan, at: key)
                continue
            }
            if scan.isBounded, boundedWalk != nil { return nil }
            let child = scan.children.removeFirst()
            queue[key] = scan
            let abandon = AbandonFlag()
            if scan.isBounded {
                boundedWalk = (DirectorySizeKey(path: child, scope: key.scope), abandon)
            }
            return Work(
                directory: key.path,
                child: child,
                backend: scan.backend,
                rule: scan.rule,
                budget: DirectorySizeBudget(directoryLimit: scan.allowance),
                abandon: abandon
            )
        }
        return nil
    }

    /// Drop a scan that has nothing left to spend, remembering every child it never reached.
    private func retire(_ scan: Scan, at key: DirectorySizeKey) {
        for child in scan.children {
            let childKey = DirectorySizeKey(path: child, scope: key.scope)
            gaveUp.insert(childKey)
            gaveUpSinceLastPublish[key, default: []].insert(child)
        }
        queue.removeValue(forKey: key)
        order.removeAll { $0 == key }
        schedulePublish()
    }

    private func startDraining() {
        guard drain == nil else { return }
        drain = Task { [weak self] in
            await self?.drainQueue()
            guard let self else { return }
            drain = nil
            // **Re-check after clearing the handle.** `drainQueue` decides it is finished, and only
            // then unwinds its task group and hands control back here — several main-actor turns
            // later. A `requestScan` landing in that window is queued while `drain` still holds a
            // task that has already stopped looking, so `startDraining` returns early and the work
            // sits there. The app heals itself (the pane re-requests on every render, so the next
            // repaint starts a fresh drain), which is why it has never been visible; a caller that
            // asks once does not, and `SizeScanQueueTests` is that caller.
            if !order.isEmpty { startDraining() }
        }
    }

    /// Walk the queue, `width` at a time, until it runs dry.
    ///
    /// A child task, not a detached one, so canceling `drain` reaches the walks themselves. The
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
                    let budget = work.budget
                    let abandon = work.abandon
                    group.addTask(priority: .utility) {
                        let result = await DirectoryLoader.cancellableSize(
                            work.backend,
                            of: work.child,
                            budget: budget,
                            excluding: exclude,
                            isAbandoned: { abandon.isAbandoned }
                        )
                        return Landing(
                            directory: work.directory,
                            child: work.child,
                            scope: scope,
                            result: result
                        )
                    }
                    running += 1
                }
                guard running > 0, let landing = await group.next() else { break }
                running -= 1
                let childKey = DirectorySizeKey(path: landing.child, scope: landing.scope)
                inFlight.remove(childKey)
                if boundedWalk?.key == childKey { boundedWalk = nil }
                guard !Task.isCancelled else { break }
                let key = DirectorySizeKey(path: landing.directory, scope: landing.scope)
                charge(landing.result.requestsMade, to: key)
                switch landing.result.outcome {
                case let .total(bytes):
                    cache.store(bytes, for: landing.child, scope: landing.scope)
                    landed[key, default: [:]][landing.child] = bytes
                    schedulePublish()
                case .gaveUp:
                    // The set's allowance ran out inside this walk. Remembered so it is not asked
                    // again, and published so the row says so rather than sitting at a dash that
                    // reads as "still measuring".
                    gaveUp.insert(childKey)
                    gaveUpSinceLastPublish[key, default: []].insert(landing.child)
                    schedulePublish()
                case .unavailable:
                    // A failed or canceled walk banks nothing: an absent total re-walks next visit,
                    // where a wrong one would be believed. The core's cache is a latency
                    // optimization and never an authority — this is the boundary that keeps it
                    // honest. Nor is it a give-up: nothing was refused, so the row keeps its dash
                    // and the next visit tries again.
                    continue
                }
            }
            group.cancelAll()
            // Whatever `cancelAll` just abandoned is no longer in flight; leaving it in the set
            // would make those children permanently unrequestable — a folder that never gets a bar
            // again for the rest of the session. The bounded slot is the same hazard one step
            // worse: a walk left recorded there blocks **every** bounded scan for the life of the
            // process, since that is exactly what it exists to do.
            inFlight.removeAll()
            boundedWalk = nil
        }
    }

    private struct Landing: Sendable {
        let directory: VFSPath
        let child: VFSPath
        let scope: DirectorySizeScope
        let result: DirectoryLoader.ScanResult
    }

    /// Subtract what a walk spent from its set's allowance, flooring at zero. A scan that has since
    /// been dropped has nothing to charge, which is the ordinary case for a landing that arrives
    /// after the pane navigated away.
    private func charge(_ requests: Int, to key: DirectorySizeKey) {
        guard var scan = queue[key], let allowance = scan.allowance else { return }
        scan.allowance = max(0, allowance - requests)
        queue[key] = scan
    }
}
