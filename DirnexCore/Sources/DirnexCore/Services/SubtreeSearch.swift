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
/// **A run that did not finish still returns its hits**, which is the exact opposite of what
/// ``DirectorySizer`` does with a partial total, on the exact opposite reasoning. A partial total is
/// a claim about the folder when the truth is a claim about the question. Partial *hits* are not:
/// every row returned really does match, and "there may be more" is a fact about the search that the
/// caller can simply say — which is what the Spotlight route's own 5000-row cap has always done.
/// That covers being stopped by the user as well as running out of limit or budget; the three are
/// three ``Completion`` values because they need three different sentences, not because they are
/// handled differently.
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
        /// `isCancelled` answered `true`.
        ///
        /// It **returns** rather than throwing, which is the one place this deliberately parts
        /// company with ``DirectorySizer`` — and the reason is who is asking. A cancelled *size*
        /// walk has no answer at all, because a partial total is a lie. A stopped *search* has
        /// forty real matches and a person standing at a Stop button who pressed it meaning
        /// "that's enough, show me". Throwing them away would be discarding exactly what they
        /// asked for, and it would also discard everything already spent finding it.
        case stopped
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

        /// A run that ended before it listed anything.
        static func nothing(_ completion: Completion) -> Results {
            Results(hits: [], directoriesListed: 0, completion: completion)
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
    ///     cancels at. Answering `true` ends the walk with ``Completion/stopped`` and the hits found
    ///     so far — see that case for why it returns where the sizer throws.
    ///
    /// - Throws: whatever a backend's ``VFSBackend/subtreeListing(at:isCancelled:)`` throws, since a
    ///   flat enumeration that failed has nothing partial to offer — and whatever listing `root`
    ///   itself throws, for the reason spelled out at that line. A failing `listDirectory` **below**
    ///   the root is not fatal and is skipped.
    public static func find(
        under root: VFSPath,
        using backend: some VFSBackend,
        matching predicate: SearchPredicate,
        budget: DirectorySizeBudget = .unbounded,
        limit: Int = .max,
        isCancelled: () -> Bool = { false },
        onProgress: (Progress) -> Void = { _ in }
    ) throws -> Results {
        guard limit > 0 else { return Results.nothing(.truncated) }
        guard !isCancelled() else { return Results.nothing(.stopped) }

        do {
            if let flat = try backend.subtreeListing(at: root, isCancelled: isCancelled) {
                let hits = Array(flat.entries.lazy.filter(predicate.matches).prefix(limit))
                onProgress(Progress(directoriesListed: 1, hits: hits.count))
                return Results(
                    hits: hits,
                    directoriesListed: 1,
                    completion: completion(forFlat: flat, hits: hits.count, limit: limit)
                )
            }
        } catch is CancellationError {
            // The shortcut's own way of saying the same thing, since it cannot return partway
            // through. Reported as a stop rather than raised, so the two routes agree about what
            // pressing Stop means.
            return Results.nothing(.stopped)
        }

        var hits: [FileEntry] = []
        // An index-advancing array rather than `removeFirst`, which is O(n) on `Array` and would
        // make a wide tree quadratic in the number of directories.
        var queue: [VFSPath] = [root]
        var head = 0
        var listed = 0

        while head < queue.count {
            if isCancelled() {
                return Results(hits: hits, directoriesListed: listed, completion: .stopped)
            }
            // Asked before the request, not after, so the limit counts listings *made* rather than
            // one made and thrown away — on a billed backend those are different numbers.
            guard budget.allows(directoriesListed: listed) else {
                return Results(hits: hits, directoriesListed: listed, completion: .budgetExceeded)
            }

            let directory = queue[head]
            head += 1
            let entries: [FileEntry]
            if directory == root {
                // The root is not a subdirectory: it is the folder being searched, so a listing that
                // fails here means there is no search rather than a gap in one. Reported instead of
                // skipped because the two are indistinguishable from the result — an empty pane —
                // and the honest reading of an empty pane is "nothing matched". A saved search is
                // what makes this reachable: it carries an absolute path from an earlier session, so
                // its scope may since have been renamed, deleted, or be on a server nobody has
                // reconnected to, and every one of those would otherwise read as "no such files".
                entries = try backend.listDirectory(at: directory)
            } else {
                // An unreadable subdirectory *is* skipped, never fatal: permission gaps are
                // ordinary, and the matches found elsewhere are still real answers.
                guard let listing = try? backend.listDirectory(at: directory) else { continue }
                entries = listing
            }
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

    /// How a shortcut's run ended, from the two things that can each cut it short.
    ///
    /// ``Completion/truncated`` wins a tie deliberately. Both can be true at once — a capped listing
    /// that nevertheless yielded a full page of hits — and the two sentences say different things:
    /// "there are more matches" is about the *answer*, which is what the user is looking at, while
    /// ``Completion/budgetExceeded`` is about the *search*. Only the second sends them to narrow the
    /// scope, and telling them to do that while the pane is already full of matches would be advice
    /// about the wrong problem.
    private static func completion(
        forFlat listing: VFSSubtreeListing,
        hits: Int,
        limit: Int
    ) -> Completion {
        if hits == limit { return .truncated }
        return listing.isComplete ? .complete : .budgetExceeded
    }
}
