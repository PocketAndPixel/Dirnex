import Foundation

/// Finds files by walking a backend's own listings, for the places that have no index to ask
/// (PLAN.md §M22) — a connected server, or an archive.
///
/// The sibling of ``DirectorySizer``: same shape (a plain synchronous function over any
/// `VFSBackend`, so the caller decides where it runs), same budget type, same "an unreadable
/// subdirectory is skipped rather than aborting the run". It differs from it in two ways, and both
/// are deliberate.
///
/// **It is breadth-first, where the sizer's stack is depth-first.** That is invisible on a walk that
/// finishes and decides everything on one that does not: a depth-first search stopped early has
/// explored a deep sliver of a single branch, where breadth-first has covered everything near the
/// top — which is where a person's file usually is, and which is also the part of the tree they can
/// still recognize in a result list.
///
/// **A truncated run returns its hits instead of throwing**, which is the exact opposite of what
/// ``DirectorySizer`` does with a partial total, on the exact opposite reasoning. A partial total is
/// a claim about the folder when the truth is a claim about the question. Partial *hits* are not:
/// every row returned really does match, and "there may be more" is a fact about the search that the
/// caller can simply say — which is what the Spotlight route's own 5000-row cap has always done.
public enum SubtreeSearch {
    /// How far a walk had got, reported as each directory is listed so a pane can show a count that
    /// moves. A remote walk runs for minutes, so a search with no visible progress is
    /// indistinguishable from one that has hung.
    public struct Progress: Sendable, Equatable {
        public let directoriesListed: Int
        public let hits: Int

        public init(directoriesListed: Int, hits: Int) {
            self.directoriesListed = directoriesListed
            self.hits = hits
        }
    }

    /// Why the walk stopped — three different sentences for the user, so they are three values and
    /// not a `Bool`.
    public enum Completion: Sendable, Equatable {
        /// The whole subtree was covered.
        case complete
        /// The result limit was reached; more matches exist.
        case truncated
        /// The ``DirectorySizeBudget`` ran out. Distinct from ``truncated`` because it says nothing
        /// about how many matches there are — it says the *search* was abandoned, and narrowing the
        /// scope is the remedy rather than narrowing the query.
        case budgetExceeded
    }

    public struct Results: Sendable, Equatable {
        public let hits: [FileEntry]
        /// How many listings were spent getting here — the number that is actually billed on a
        /// remote backend. A backend answering through ``VFSBackend/subtreeListing(at:isCancelled:)``
        /// reports **1**, since it returned the whole subtree in one call however many pages that
        /// took internally.
        public let directoriesListed: Int
        public let completion: Completion

        public init(hits: [FileEntry], directoriesListed: Int, completion: Completion) {
            self.hits = hits
            self.directoriesListed = directoriesListed
            self.completion = completion
        }
    }

    /// Every entry beneath `root` that `predicate` matches.
    ///
    /// `root` itself is never tested: it is the folder being searched *in*, and returning it as its
    /// own hit is noise in every case where it would match.
    ///
    /// Symlinks are never descended into — a link's target is somewhere else and may be a cycle —
    /// so only real directories are pushed. A symlink can still *match*, as any other row can.
    ///
    /// - Parameters:
    ///   - budget: how many directories may be listed before giving up. `.unbounded` locally and in
    ///     an archive, ``DirectorySizeBudget/remote`` on a connected server, which is one place
    ///     rather than a number at this call site.
    ///   - limit: the most hits to gather. Defaults to no limit; the app passes its rendering cap.
    ///   - isCancelled: polled before every listing, at the same one-listing granularity the sizer
    ///     cancels at. Throws `CancellationError`, since a cancelled search has no answer at all —
    ///     unlike a truncated one, which has a partial answer worth showing.
    public static func find(
        under root: VFSPath,
        using backend: some VFSBackend,
        matching predicate: SearchPredicate,
        budget: DirectorySizeBudget = .unbounded,
        limit: Int = .max,
        isCancelled: () -> Bool = { false },
        onProgress: (Progress) -> Void = { _ in }
    ) throws -> Results {
        guard limit > 0 else { return Results(hits: [], directoriesListed: 0, completion: .truncated) }
        if isCancelled() { throw CancellationError() }

        if let flat = try backend.subtreeListing(at: root, isCancelled: isCancelled) {
            let hits = Array(flat.lazy.filter(predicate.matches).prefix(limit))
            onProgress(Progress(directoriesListed: 1, hits: hits.count))
            return Results(
                hits: hits,
                directoriesListed: 1,
                completion: hits.count == limit ? .truncated : .complete
            )
        }

        var hits: [FileEntry] = []
        // An index-advancing array rather than `removeFirst`, which is O(n) on `Array` and would
        // make a wide tree quadratic in the number of directories.
        var queue: [VFSPath] = [root]
        var head = 0
        var listed = 0

        while head < queue.count {
            if isCancelled() { throw CancellationError() }
            // Asked before the request, not after, so the limit counts listings *made* rather than
            // one made and thrown away — on a billed backend those are different numbers.
            guard budget.allows(directoriesListed: listed) else {
                return Results(hits: hits, directoriesListed: listed, completion: .budgetExceeded)
            }

            let directory = queue[head]
            head += 1
            // An unreadable subdirectory is skipped, never fatal: permission gaps are ordinary, and
            // the matches found elsewhere are still real answers.
            guard let entries = try? backend.listDirectory(at: directory) else { continue }
            listed += 1

            for entry in entries {
                if entry.isDirectory { queue.append(entry.path) }
                guard predicate.matches(entry) else { continue }
                hits.append(entry)
                if hits.count >= limit {
                    onProgress(Progress(directoriesListed: listed, hits: hits.count))
                    return Results(hits: hits, directoriesListed: listed, completion: .truncated)
                }
            }
            onProgress(Progress(directoriesListed: listed, hits: hits.count))
        }

        return Results(hits: hits, directoriesListed: listed, completion: .complete)
    }
}
