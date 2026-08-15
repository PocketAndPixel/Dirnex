import DirnexCore
import Foundation

/// Runs a ``SearchPredicate`` over a backend's own listings, off the main thread — the route ⌥F7
/// takes where there is no index to ask (PLAN.md §M22).
///
/// The sibling of `SpotlightSearchRunner`, and the same division of labour: everything about *what
/// matches* and *when to stop* is the tested `DirnexCore.SubtreeSearch`, and this owns only the
/// non-hermetic part — getting it off the main thread and giving the sheet something to watch.
///
/// It needs no per-hit `stat`, which is the one way it is cheaper than the Spotlight route: `mdfind`
/// hands back bare paths, while a walk gets whole `FileEntry`s out of the listings it has already
/// paid for.
enum SubtreeSearchRunner {
    /// Search `scope`'s subtree for whatever `predicate` accepts.
    ///
    /// The budget comes from the scope's own backend, so a connected server is bounded and an
    /// archive is not, with the number living in `DirectorySizeBudget` rather than here. `limit` is
    /// the same rendering cap the Spotlight route uses — a pane can only show so many rows, whatever
    /// found them.
    static func run(
        _ predicate: SearchPredicate,
        under scope: VFSPath,
        backend: any VFSBackend,
        limit: Int = SpotlightSearchRunner.resultLimit,
        control: SearchControl
    ) async throws -> SubtreeSearch.Results {
        try await Task.detached(priority: .userInitiated) {
            try SubtreeSearch.find(
                under: scope,
                using: backend,
                matching: predicate,
                budget: .forBackend(scope.backend),
                limit: limit,
                isCancelled: { control.isStopped },
                onProgress: { control.report($0) }
            )
        }.value
    }
}

/// The two-way channel between a running walk and whoever is watching it: Stop goes down, progress
/// comes up.
///
/// **Progress is published for polling rather than delivered as a callback**, and that is a decision
/// rather than laziness. A walk reports once per directory — hundreds of times a second on a local
/// archive — so a callback reaching the main actor needs coalescing, and docs/NOTES.md records what
/// goes wrong when a coalescer *drops* what it withholds instead of deferring it: the last update
/// inside the quiet window is lost, and if nothing follows it the display latches on a stale value
/// forever. A latest-value box cannot latch, because the reader always sees the newest value there
/// is, and the run's own completion is what replaces the display at the end.
final class SearchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var latest = SubtreeSearch.Progress(directoriesListed: 0, hits: 0)

    init() {}

    /// Polled by the walk before every listing. Once true it stays true.
    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// The most recent progress the walk published.
    var progress: SubtreeSearch.Progress {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Ask the walk to stop at its next listing boundary. It keeps the hits it has already found —
    /// see `SubtreeSearch.Completion.stopped`.
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func report(_ progress: SubtreeSearch.Progress) {
        lock.lock()
        latest = progress
        lock.unlock()
    }
}
