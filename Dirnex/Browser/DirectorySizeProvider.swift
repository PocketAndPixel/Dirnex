import DirnexCore
import Foundation

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
    /// *displayed* directory rather than by pane, so two panes on one folder coalesce.
    private var queue: [VFSPath: Scan] = [:]
    /// Requested directories, **most recently requested last** — the order `nextWork` drains in
    /// reverse. Newest-first is the whole point: navigating to a new folder must not wait behind the
    /// queue of one the user has already left.
    private var order: [VFSPath] = []
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
    private var inFlight: Set<VFSPath> = []
    /// Directories whose totals have changed since the last publish.
    private var dirty: Set<VFSPath> = []
    private var publish: Task<Void, Never>?

    private struct Scan {
        /// The backend to walk with — carried per request because the provider is shared while
        /// backends are the panes'. `VFSBackend` is `Sendable`, so it crosses to the walk freely.
        let backend: any VFSBackend
        /// Children still owing a walk, in display order.
        var children: [VFSPath]
    }

    // MARK: - Reading (the render path)

    /// Every total already known among `paths` — what a pane seeds itself from on arrival, in one
    /// bulk `Panel.setDirectorySizes` rather than one call per row. Pass 9 measured why that matters:
    /// seeding one-by-one re-sorts the listing per call and costs 2.5 s at 3,000 rows, which would
    /// make the cache slower than having no cache at the one job it has.
    func cachedSizes(for paths: [VFSPath]) -> [VFSPath: Int64] {
        var known: [VFSPath: Int64] = [:]
        for path in paths {
            guard let bytes = cache.size(for: path) else { continue }
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
    func requestScan(for directory: VFSPath, children: [VFSPath], backend: any VFSBackend) {
        let unknown = children.filter { cache.size(for: $0) == nil && !inFlight.contains($0) }
        guard !unknown.isEmpty else {
            // Nothing to do — but the directory may have had work a moment ago (everything just
            // landed, or the cache was seeded), so clear it rather than leave a spent entry behind.
            cancelScan(for: directory)
            return
        }
        queue[directory] = Scan(backend: backend, children: unknown)
        order.removeAll { $0 == directory }
        order.append(directory)
        startDraining()
    }

    /// Drop `directory`'s outstanding work — the pane navigated away, switched tabs, or left the
    /// mode. Walks already in flight are left to finish: their answer is still true, the cache is
    /// keyed by path rather than by who asked, and abandoning a walk that is nearly done only means
    /// paying for it again on the way back. The mid-walk cancellation that
    /// `DirectoryLoader.cancellableSize` provides is for the whole queue going quiet, below.
    func cancelScan(for directory: VFSPath) {
        queue.removeValue(forKey: directory)
        order.removeAll { $0 == directory }
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

    /// One walk to perform: which child, on whose behalf, with what.
    private struct Work {
        let directory: VFSPath
        let child: VFSPath
        let backend: any VFSBackend
    }

    /// The next child to walk: from the **most recently requested** directory that still owes work.
    private func nextWork() -> Work? {
        while let directory = order.last {
            guard var scan = queue[directory], !scan.children.isEmpty else {
                // Spent or cancelled — drop it and look at the next-newest.
                queue.removeValue(forKey: directory)
                order.removeLast()
                continue
            }
            let child = scan.children.removeFirst()
            queue[directory] = scan
            return Work(directory: directory, child: child, backend: scan.backend)
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
                    inFlight.insert(work.child)
                    group.addTask(priority: .utility) {
                        let bytes = await DirectoryLoader.cancellableSize(
                            work.backend,
                            of: work.child
                        )
                        return Landing(directory: work.directory, child: work.child, bytes: bytes)
                    }
                    running += 1
                }
                guard running > 0, let landing = await group.next() else { break }
                running -= 1
                inFlight.remove(landing.child)
                guard !Task.isCancelled else { break }
                // A failed or cancelled walk banks nothing: an absent total re-walks next visit,
                // where a wrong one would be believed. The core's cache is a latency optimization
                // and never an authority — this is the boundary that keeps it honest.
                guard let bytes = landing.bytes else { continue }
                cache.store(bytes, for: landing.child)
                dirty.insert(landing.directory)
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
        let directories = dirty
        dirty = []
        for directory in directories {
            NotificationCenter.default.post(
                name: Self.didChangeNotification,
                object: self,
                userInfo: [Self.directoryKey: directory]
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
}
