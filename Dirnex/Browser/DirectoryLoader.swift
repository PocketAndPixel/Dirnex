import DirnexCore
import Foundation

/// Bridges the synchronous, pure `VFSBackend` listing API into the async world of
/// the UI without ever blocking the main thread (PLAN.md §1 "listing must never
/// block the UI").
///
/// The backend's read methods are documented as safe off the main thread, so the blocking walk
/// runs through `BlockingWork` — a thread it is *allowed* to block — and only the resulting
/// `Sendable` value crosses back to the caller's actor.
///
/// **Not `Task.detached`, which is the cooperative pool.** A listing is a blocking call whatever
/// the backend: `readdir` on this disk, and a real network round trip on a remote one (0.601–0.699 s
/// per `ListObjectsV2`, measured — docs/NOTES.md ▸ curl for S3). A detached task that blocks parks
/// one of the pool's workers, and the pool's width is the machine's core count and does not
/// over-commit — measured here at 16 blocked bodies on a 16-core Mac and **1** under
/// `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`. That is the shape `BlockingWork`'s own doc comment was
/// written for, and the one that failed a CI release build once already.
///
/// `sorted` is the deliberate exception: it reads nothing, so the pool is exactly where it belongs.
enum DirectoryLoader {
    static func list(_ backend: any VFSBackend, at path: VFSPath) async throws -> DirectoryListing {
        // `BlockingWork.run` is deliberately non-throwing, so the backend's error rides back as a
        // `Result` — the shape `RemoteFileCache.fetch` already uses.
        try await BlockingWork.run { () -> Result<DirectoryListing, any Error> in
            Result {
                let entries = try backend.listDirectory(at: path)
                return DirectoryListing(path: path, entries: entries)
            }
        }.get()
    }

    /// List `path` **and** sort it into a ready-to-render `DirectoryModel`, both off the main
    /// thread — so opening a 100k directory never runs its ~350 ms `localizedStandardCompare` sort
    /// on the `@MainActor` pane (PLAN.md §M7 perf pass). Install the result with `Panel.setModel`.
    ///
    /// The text `filter` is deliberately *not* baked in: it is cheap to apply (~1 ms) and must
    /// reflect the caller's latest keystroke, so the caller sets it on the main actor after the
    /// `await`. `directorySizes` seed size-sorting (pruned to present entries by the model); pass
    /// empty when navigating to a fresh directory, which has no computed totals yet.
    static func model(
        _ backend: any VFSBackend,
        at path: VFSPath,
        sort: FileSort,
        showHidden: Bool,
        directorySizes: [VFSPath: Int64] = [:]
    ) async throws -> DirectoryModel {
        try await BlockingWork.run { () -> Result<DirectoryModel, any Error> in
            Result {
                let entries = try backend.listDirectory(at: path)
                let listing = DirectoryListing(path: path, entries: entries)
                return DirectoryModel(
                    listing: listing,
                    sort: sort,
                    showHidden: showHidden,
                    directorySizes: directorySizes
                )
            }
        }.get()
    }

    /// Re-project an **already-loaded** listing under a new sort/hidden setting off the main
    /// thread — the column-header re-sort and the show-hidden toggle, which change the row order
    /// without re-reading the directory. Same filter/sizes contract as `model`.
    ///
    /// **Stays on `Task.detached`, deliberately.** This reads nothing: it is ~350 ms of
    /// `localizedStandardCompare` on a 100k directory and never blocks on I/O, which is precisely
    /// the work the cooperative pool exists to run. Sending it to `BlockingWork` would buy nothing
    /// and give up the pool's core-count parallelism.
    static func sorted(
        _ listing: DirectoryListing,
        sort: FileSort,
        showHidden: Bool,
        directorySizes: [VFSPath: Int64] = [:]
    ) async -> DirectoryModel {
        await Task.detached(priority: .userInitiated) {
            DirectoryModel(
                listing: listing,
                sort: sort,
                showHidden: showHidden,
                directorySizes: directorySizes
            )
        }.value
    }

    /// Stat a single path off the main thread — used to check whether a typed location is a
    /// real directory before deciding to fall back to a frecency fuzzy match. Returns `nil`
    /// on any failure (not found, permission, …), so the caller treats a missing path the
    /// same as an un-stattable one.
    static func stat(_ backend: any VFSBackend, at path: VFSPath) async -> FileEntry? {
        await BlockingWork.run { try? backend.stat(at: path) }
    }

    /// Recursively total a directory's size off the main thread (Space-on-dir sizing).
    /// Returns `nil` only if the top-level walk fails outright; unreadable subtrees are
    /// skipped inside `DirectorySizer`, not fatal. Runs at `.utility` — sizing is a
    /// background nicety and must never contend with an interactive listing.
    ///
    /// **It outlives its caller's cancellation** — deliberate for Space-on-dir, where the walk the
    /// user explicitly asked for should finish and land in the cache even if they arrow onward.
    /// Size-visualization mode wants the opposite and uses `cancellableSize`.
    ///
    /// `BlockingWork` keeps that property and strengthens it: `withCheckedContinuation` does not
    /// carry cancellation, so the walk is uncancellable *by construction* rather than by relying on
    /// a detached task not inheriting it. Nothing here reads a cancellation flag — `DirectorySizer`
    /// is called with its default `isCancelled`, which is why this one converts with no bridge.
    static func size(
        _ backend: any VFSBackend,
        of path: VFSPath,
        excluding isExcluded: @escaping @Sendable (VFSPath) -> Bool = { _ in false }
    ) async -> Int64? {
        await BlockingWork.run(qos: .utility) {
            try? DirectorySizer.size(of: path, using: backend, excluding: isExcluded)
        }
    }

    /// The same walk, but abandonable **mid-walk** rather than merely discarded on completion.
    ///
    /// Size-visualization mode's auto-scan needs this and `size` cannot give it: a detached task
    /// does not inherit cancellation, so a `/System` walk started by a mode the user has since
    /// switched off would grind on to completion with nowhere to put its answer. Run as a *child*
    /// task (this is not detached), it inherits cancellation from the scan queue's task group, and
    /// `DirectorySizer` checks the flag at every directory it pops.
    ///
    /// Returns `nil` when canceled, exactly as it does when the walk fails — both mean "no total",
    /// and the cache stores neither.
    ///
    /// `isExcluded` prunes subtrees out of the total — `.gitignore`-aware sizing, whose predicate is
    /// `GitStatusSnapshot.isExcludedFromSize`. It is `@Sendable` because it crosses onto the walk's
    /// task; the snapshot it closes over is a `Sendable` value, so nothing is shared.
    static func cancellableSize(
        _ backend: any VFSBackend,
        of path: VFSPath,
        excluding isExcluded: @escaping @Sendable (VFSPath) -> Bool = { _ in false }
    ) async -> Int64? {
        try? DirectorySizer.size(
            of: path,
            using: backend,
            excluding: isExcluded,
            isCancelled: { Task.isCancelled }
        )
    }

    /// How a budgeted walk ended. Three outcomes rather than an `Int64?`, because a walk that
    /// **gave up** and one that failed look identical from outside and mean opposite things to the
    /// person watching: one says "this folder is bigger than we will count over a network", the
    /// other says "we could not read it". Collapsing them puts the same dash on both and invites
    /// the user to press Space again on the one that will cost another thousand requests.
    enum SizeOutcome: Sendable, Equatable {
        case total(Int64)
        /// The walk reached its ``DirectorySizeBudget``. Deliberately carries no partial — see that
        /// type for why a partial rendered as the answer is a claim about the wrong thing.
        case gaveUp
        /// Cancelled, or the top-level listing failed. Both mean "no total" and the cache stores
        /// neither, which is the pre-existing meaning of this function's `nil`.
        case unavailable
    }

    /// The Space-on-dir walk for a backend whose listings are **billed round trips** (PLAN.md §M21
    /// Slice 11) — bounded by `budget`, and abandonable through the returned task's own handle.
    ///
    /// It is `Task.detached` for the same reason `size` is: the walk blocks, so it must not run on
    /// the caller's main actor. What differs is that the caller *keeps* the handle. A detached task
    /// does not inherit cancellation, which is exactly right here — nothing should cancel this
    /// except the pane deciding it has stopped looking, and it says so by calling `cancel()`.
    ///
    /// Measured against the live endpoint before it was written: cancelling lands within one
    /// listing (~0.6 s there), because `DirectorySizer` reads the flag once per directory popped.
    static func budgetedSize(
        _ backend: any VFSBackend,
        of path: VFSPath,
        budget: DirectorySizeBudget,
        excluding isExcluded: @escaping @Sendable (VFSPath) -> Bool = { _ in false }
    ) -> Task<SizeOutcome, Never> {
        Task.detached(priority: .utility) {
            do {
                let total = try DirectorySizer.size(
                    of: path,
                    using: backend,
                    budget: budget,
                    excluding: isExcluded,
                    isCancelled: { Task.isCancelled }
                )
                return .total(total)
            } catch is DirectorySizeBudgetExceeded {
                return .gaveUp
            } catch {
                return .unavailable
            }
        }
    }
}
