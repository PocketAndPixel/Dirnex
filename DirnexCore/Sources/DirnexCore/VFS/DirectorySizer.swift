/// Recursively totals the logical byte size of a directory subtree by walking a
/// `VFSBackend`. This is the engine behind Total Commander's Space-on-directory
/// in-place sizing (PLAN.md §M1): the panel shows a folder's real weight in the size
/// column instead of a dash.
///
/// It lives in `DirnexCore` because it touches bytes ("if it touches bytes, it lives
/// in DirnexCore and has tests" — §2), and is a plain synchronous function so the
/// caller decides where it runs. The app runs it on a background queue and applies
/// the result on the main actor.
public enum DirectorySizer {
    /// The recursive byte total of everything beneath `path`.
    ///
    /// - Only files (and non-directory special entries) contribute bytes; a directory
    ///   adds its contents, not its own inode size — matching how TC reports a folder's
    ///   weight.
    /// - Symlinks are counted by their own (link) size and never followed, so a symlink
    ///   cycle cannot wedge the walk. The top-level `path` is still opened normally, so
    ///   sizing a directory reached through a symlink works.
    /// - An unreadable subdirectory is skipped rather than aborting the whole total; a
    ///   partial number beats no number, and permission gaps are common.
    ///
    /// The walk is iterative (an explicit stack) so arbitrarily deep trees cannot blow
    /// the call stack. Pass `isCancelled` to abandon a huge tree when the user has
    /// navigated away — it throws `CancellationError` in that case.
    ///
    /// `isExcluded` leaves a subtree out of the total entirely — the `.gitignore`-aware sizing of
    /// §M6, whose predicate is `GitStatusSnapshot.isExcludedFromSize`. An excluded *directory* is
    /// never pushed onto the stack, so it costs nothing to leave out rather than being walked and
    /// then discarded. That pruning is most of the point: walk cost tracks **entry count**, not
    /// bytes (a 1 TB `~/Movies` walks fast where a 17 GB `node_modules` does not), so skipping the
    /// build output is also what makes the mode fast enough to leave on.
    ///
    /// The top-level `path` is never tested — sizing a folder you explicitly pointed at must
    /// produce a number even when it is itself ignored, or the ignored rows in a listing would all
    /// read as empty.
    ///
    /// `budget` bounds how many directories the walk may list, and defaults to
    /// ``DirectorySizeBudget/unbounded`` so it changed no caller when it arrived. It exists for the
    /// remote backends, where a directory is a billed request at a network round trip rather than
    /// a `readdir` — see that type for the measurement and for why it throws instead of returning
    /// a partial.
    ///
    /// **Label both closures at the call site.** With two of them a bare trailing closure binds to
    /// `excluding`, not to `isCancelled` — which is silently the opposite of what every pre-existing
    /// caller meant, and only failed loudly here because the two have different arities.
    public static func size(
        of path: VFSPath,
        using backend: some VFSBackend,
        budget: DirectorySizeBudget = .unbounded,
        excluding isExcluded: (VFSPath) -> Bool = { _ in false },
        isCancelled: () -> Bool = { false }
    ) throws -> Int64 {
        try measure(
            of: path,
            using: backend,
            budget: budget,
            excluding: isExcluded,
            isCancelled: isCancelled
        ).bytes
    }

    /// The same walk, reporting what it **spent** as well as what it found — see
    /// ``DirectorySizeMeasurement``. `size` is this with the cost dropped, so the two can never
    /// disagree about the bytes.
    ///
    /// **It asks the backend for the whole subtree first** (``VFSBackend/subtreeListing(at:isCancelled:)``,
    /// M22's seam), and only walks when there is no such answer. That is the difference between a
    /// remote folder costing a round trip per directory and costing one request: measured against a
    /// real `sshd` over 136 directories, **19.24 s and 137 sessions** walking against **0.156 s and
    /// 1 session** through the shortcut, with the totals identical to the byte (748 654 each way).
    /// The seam was built for search and adopted by ``DirectorySync``; this is its third consumer,
    /// and the sizer had been the one asking for everything the expensive way.
    ///
    /// Three rules about when the shortcut is *not* taken, each of which fails safe into the walk:
    ///
    /// - A backend with no shortcut answers `nil`, which is every local path and an SFTP account
    ///   confined to `internal-sftp` (``SFTPBackend`` degrades per connection by design).
    /// - An **incomplete** listing is refused. SFTP caps its own output because a `find` over a
    ///   home directory would otherwise be megabytes down one channel, and a capped slice summed as
    ///   a total is a confident wrong number — the quiet direction. The walk that follows is
    ///   bounded and says ``DirectorySizeBudgetExceeded`` honestly.
    /// - A shortcut that **throws** falls back too, since the walk standing behind it will surface a
    ///   real failure with a real error. Cancellation is the one thing that travels, because it is
    ///   the caller's own instruction.
    public static func measure(
        of path: VFSPath,
        using backend: some VFSBackend,
        budget: DirectorySizeBudget = .unbounded,
        excluding isExcluded: (VFSPath) -> Bool = { _ in false },
        isCancelled: () -> Bool = { false }
    ) throws -> DirectorySizeMeasurement {
        if isCancelled() { throw CancellationError() }
        // An allowance already spent refuses *everything*, the shortcut included — otherwise a set
        // whose budget ran out would go on spending one request per remaining row.
        guard budget.allows(directoriesListed: 0) else {
            throw DirectorySizeBudgetExceeded(directoriesListed: 0)
        }
        if let bytes = try shortcutTotal(
            of: path, using: backend, excluding: isExcluded, isCancelled: isCancelled
        ) {
            // One request, whatever the tree holds. The shortcut is deliberately outside `budget`,
            // which counts *listings made*: bounding one request by a thousand-directory allowance
            // would refuse the cheap answer for the expensive one's reason. Each backend bounds its
            // own shortcut instead — `S3Backend.pageLimit` and `SFTPBackend.subtreeRowLimit`.
            return DirectorySizeMeasurement(bytes: bytes, requestsMade: 1)
        }
        return try walk(
            of: path,
            using: backend,
            budget: budget,
            excluding: isExcluded,
            isCancelled: isCancelled
        )
    }

    /// The subtree the backend can hand over without being walked, summed — or `nil` for "walk
    /// instead", which covers all three refusals in `measure`'s note.
    private static func shortcutTotal(
        of path: VFSPath,
        using backend: some VFSBackend,
        excluding isExcluded: (VFSPath) -> Bool,
        isCancelled: () -> Bool
    ) throws -> Int64? {
        let listing: VFSSubtreeListing?
        do {
            listing = try backend.subtreeListing(at: path, isCancelled: isCancelled)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        guard let listing, listing.isComplete else { return nil }
        return total(of: listing.entries, excluding: isExcluded)
    }

    /// A flat subtree summed under the same rules the walk applies, which is the whole of what
    /// makes the two interchangeable: only non-directories carry bytes, a symlink counts as its own
    /// link size, and an excluded **directory** takes its subtree with it.
    ///
    /// Pruning is done in two passes rather than by trusting the listing's order. A walk never
    /// pushes an excluded directory, so nothing beneath one is ever seen; a flat listing contains
    /// those descendants and they have to be dropped by ancestry. Ordering is not assumed, because
    /// it is the backend's and this must not depend on it.
    private static func total(
        of entries: [FileEntry],
        excluding isExcluded: (VFSPath) -> Bool
    ) -> Int64 {
        var prunedRoots: [VFSPath] = []
        for entry in entries where isExcluded(entry.path) { prunedRoots.append(entry.path) }
        var total: Int64 = 0
        for entry in entries where entry.kind != .directory {
            if !prunedRoots.isEmpty,
               prunedRoots.contains(where: { entry.path.isSelfOrDescendant(of: $0) }) { continue }
            total += entry.byteSize
        }
        return total
    }

    /// The original directory-at-a-time walk, unchanged but for reporting what it listed.
    private static func walk(
        of path: VFSPath,
        using backend: some VFSBackend,
        budget: DirectorySizeBudget,
        excluding isExcluded: (VFSPath) -> Bool,
        isCancelled: () -> Bool
    ) throws -> DirectorySizeMeasurement {
        var total: Int64 = 0
        var stack: [VFSPath] = [path]
        var listed = 0
        while let directory = stack.popLast() {
            if isCancelled() { throw CancellationError() }
            // Checked before the request, not after, so the limit is a count of listings *made*
            // rather than one made and thrown away — on a billed backend those are different
            // numbers, and the one that matters is what was spent.
            guard budget.allows(directoriesListed: listed) else {
                throw DirectorySizeBudgetExceeded(directoriesListed: listed)
            }
            let entries: [FileEntry]
            do {
                listed += 1
                entries = try backend.listDirectory(at: directory)
            } catch {
                continue // unreadable subtree contributes nothing
            }
            for entry in entries {
                if isExcluded(entry.path) { continue }
                if entry.kind == .directory {
                    stack.append(entry.path)
                } else {
                    total += entry.byteSize
                }
            }
        }
        return DirectorySizeMeasurement(bytes: total, requestsMade: listed)
    }
}

/// What one recursive size walk produced, and what it spent producing it.
///
/// The second field exists so a *set* of walks can be bounded: size-visualization mode asks for
/// every sibling's total at once, and an allowance held across the set has to be told what each
/// walk actually cost (`DirectorySizeBudget.forSet(ofBackend:)`). Nothing can be inferred from the
/// total — a folder of one enormous file and a folder of ten thousand small ones are the same
/// number of bytes and a thousand-fold difference in requests.
public struct DirectorySizeMeasurement: Sendable, Equatable {
    /// The recursive byte total.
    public let bytes: Int64
    /// How many **requests** reaching the backend it took.
    ///
    /// Requests rather than directories, because the two part company the moment a backend can
    /// answer a whole subtree at once: a walk makes exactly one listing per directory — the
    /// quantity ``DirectorySizeBudget`` bounds — while a shortcut makes **one**, whatever the tree
    /// holds. Measured 2026-09-01 against a real `sshd` over 136 directories: 137 sessions and
    /// 19.24 s for the walk, 1 session and 0.156 s for the shortcut, identical totals.
    public let requestsMade: Int

    public init(bytes: Int64, requestsMade: Int) {
        self.bytes = bytes
        self.requestsMade = requestsMade
    }
}
