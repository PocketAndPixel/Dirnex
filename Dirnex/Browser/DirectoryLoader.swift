import DirnexCore
import Foundation

/// Bridges the synchronous, pure `VFSBackend` listing API into the async world of
/// the UI without ever blocking the main thread (PLAN.md §1 "listing must never
/// block the UI").
///
/// The backend's read methods are documented as safe off the main thread, so the
/// blocking `readdir` walk runs on a detached task; only the resulting `Sendable`
/// `DirectoryListing` crosses back to the caller's actor.
enum DirectoryLoader {
    static func list(_ backend: any VFSBackend, at path: VFSPath) async throws -> DirectoryListing {
        try await Task.detached(priority: .userInitiated) {
            let entries = try backend.listDirectory(at: path)
            return DirectoryListing(path: path, entries: entries)
        }.value
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
        try await Task.detached(priority: .userInitiated) {
            let entries = try backend.listDirectory(at: path)
            let listing = DirectoryListing(path: path, entries: entries)
            return DirectoryModel(
                listing: listing,
                sort: sort,
                showHidden: showHidden,
                directorySizes: directorySizes
            )
        }.value
    }

    /// Re-project an **already-loaded** listing under a new sort/hidden setting off the main
    /// thread — the column-header re-sort and the show-hidden toggle, which change the row order
    /// without re-reading the directory. Same filter/sizes contract as `model`.
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
        await Task.detached(priority: .userInitiated) {
            try? backend.stat(at: path)
        }.value
    }

    /// Recursively total a directory's size off the main thread (Space-on-dir sizing).
    /// Returns `nil` only if the top-level walk fails outright; unreadable subtrees are
    /// skipped inside `DirectorySizer`, not fatal. Runs at `.utility` — sizing is a
    /// background nicety and must never contend with an interactive listing.
    ///
    /// **Detached, so it outlives its caller's cancellation** — deliberate for Space-on-dir, where
    /// the walk the user explicitly asked for should finish and land in the cache even if they
    /// arrow onward. Size-visualization mode wants the opposite and uses `cancellableSize`.
    static func size(
        _ backend: any VFSBackend,
        of path: VFSPath,
        excluding isExcluded: @escaping @Sendable (VFSPath) -> Bool = { _ in false }
    ) async -> Int64? {
        await Task.detached(priority: .utility) {
            try? DirectorySizer.size(of: path, using: backend, excluding: isExcluded)
        }.value
    }

    /// The same walk, but abandonable **mid-walk** rather than merely discarded on completion.
    ///
    /// Size-visualization mode's auto-scan needs this and `size` cannot give it: a detached task
    /// does not inherit cancellation, so a `/System` walk started by a mode the user has since
    /// switched off would grind on to completion with nowhere to put its answer. Run as a *child*
    /// task (this is not detached), it inherits cancellation from the scan queue's task group, and
    /// `DirectorySizer` checks the flag at every directory it pops.
    ///
    /// Returns `nil` when cancelled, exactly as it does when the walk fails — both mean "no total",
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
}
