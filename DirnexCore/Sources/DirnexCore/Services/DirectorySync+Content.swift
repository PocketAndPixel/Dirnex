import Foundation

/// Comparing by contents when the contents are not on this disk (PLAN.md §M25 Slice 5d).
///
/// M24's one structural rule is that the **gesture** materializes and the engine never does, and a
/// directory sync is where that rule is hardest to keep: nothing can know which files a content
/// comparison will read until both trees have been walked, and by then the walk is over. So the
/// scan is two phases over **one** walk:
///
/// 1. ``DirectorySync/survey(left:right:leftBackend:rightBackend:isCancelled:)`` walks the pair once
///    and classifies every row by size alone, keeping the identical ones. Nothing is read and
///    nothing is fetched.
/// 2. ``DirectorySync/contentCandidates(in:)`` names the pairs whose bytes decide the answer, the
///    gesture weighs and fetches exactly those, and
///    ``DirectorySync/recompare(_:between:and:comparison:tolerance:includingIdentical:contentsEqual:)``
///    re-answers the same rows with the bytes now readable.
///
/// **One walk rather than two**, which is the difference from the shape checksum verification had
/// to settle for: there the gesture and the run each walk, because a manifest names files that may
/// not exist and the two walks are seconds apart. Here the rows *are* the plan, so the set the
/// confirmation counted and the set the comparison reads cannot drift — the failure docs/NOTES.md
/// records for every gesture that works out what a run will do and then works it out again.
///
/// **What is deliberately not fetched is an evicted cloud placeholder.** The engine's default
/// comparator refuses to read through one, and that refusal stands here: a placeholder cannot be
/// *weighed* (``MaterializationPlan`` excludes it, since `CloudDownloadPrompt` is its own progress
/// surface), so fetching every one a tree walk discovered would be an unbounded download nobody was
/// shown a total for. M14's rule — a file somebody pointed at downloads, a tree sweep refuses —
/// unchanged. A remote row is the opposite case and is why this slice exists: it is not a file at
/// all until it is fetched, and what it costs is exact and is named before anything starts.
public extension DirectorySync {
    /// Walk the two trees once and classify every row by size, keeping the identical ones — the raw
    /// material every comparison the sheet offers is then derived from, without walking again.
    ///
    /// Size is chosen because it is the only classification that reads nothing and consults no
    /// clock, so it can be taken over any pair; `includingIdentical` is `true` because the rows a
    /// size comparison calls identical are exactly the ``contentCandidates(in:)`` — dropping them
    /// here would leave the content phase with nothing to read and no way to know it had been
    /// robbed. Both are the point of this function existing rather than the caller spelling out a
    /// `compare` call: they are a precondition of the second phase, and a precondition somebody has
    /// to remember is one that eventually goes missing.
    static func survey(
        left: VFSPath,
        right: VFSPath,
        leftBackend: some VFSBackend,
        rightBackend: some VFSBackend,
        isCancelled: () -> Bool = { false }
    ) throws -> [SyncEntry] {
        try compare(
            left: left,
            right: right,
            leftBackend: leftBackend,
            rightBackend: rightBackend,
            comparison: .size,
            includingIdentical: true,
            isCancelled: isCancelled
        )
    }

    /// The rows whose bytes a ``SyncComparison/content`` scan will actually read.
    ///
    /// Both sides present, both regular files, and the same size — a size mismatch is already an
    /// answer, and a symlink or a special file has no contents to compare. Selected by the *same*
    /// predicate the engine uses when it decides whether to call the comparator
    /// (``DirectorySync/contentReadsBytes(_:_:)``), so what a gesture fetches and what the scan
    /// reads are one definition. Two spellings would fail in the quiet direction: every pair the
    /// gesture failed to predict throws mid-scan, over a file sitting right in front of the user.
    ///
    /// Expects the rows ``survey(left:right:leftBackend:rightBackend:isCancelled:)`` produced. Given
    /// a list that dropped its identical rows this answers with fewer candidates and says nothing —
    /// which is the whole reason the survey is a named function rather than a `compare` call.
    static func contentCandidates(in entries: [SyncEntry]) -> [SyncEntry] {
        entries.filter { entry in
            guard let left = entry.left, let right = entry.right else { return false }
            return contentReadsBytes(left, right)
        }
    }

    /// Re-answer `entries` under a different comparison, reading nothing but the bytes
    /// `contentsEqual` resolves — no directory is listed and no tree is walked.
    ///
    /// A row's classification is a pure function of the two ``FileEntry`` values the walk captured,
    /// so switching the sheet's comparison picker is a derivation rather than a re-scan, and the
    /// content phase can re-answer exactly the rows its fetch was planned from. Rows that are
    /// **structural** — present on one side only, or a file against a directory — pass through
    /// untouched: no comparison can change what they are.
    ///
    /// - Parameters:
    ///   - left: the left side's backend, and `right` the right's. They decide only whether the
    ///     clock may be believed (``SyncComparison/believesModificationDates(between:and:)``), which
    ///     is a fact about the pair and not about any row.
    ///   - contentsEqual: as ``compare(left:right:leftBackend:rightBackend:comparison:tolerance:includingIdentical:isCancelled:contentsEqual:)``
    ///     — and here it is normally a closure resolving each side through
    ///     ``MaterializedPaths`` before handing two real local paths to ``ByteComparator``.
    static func recompare(
        _ entries: [SyncEntry],
        between left: VFSBackendID,
        and right: VFSBackendID,
        comparison: SyncComparison,
        tolerance: TimeInterval = defaultTolerance,
        includingIdentical: Bool = false,
        contentsEqual: (VFSPath, VFSPath) throws -> Bool = { try ByteComparator.localFilesEqual(
            $0,
            $1
        ) }
    ) throws -> [SyncEntry] {
        let believesClock = comparison.believesModificationDates(between: left, and: right)
        var results: [SyncEntry] = []
        results.reserveCapacity(entries.count)
        for entry in entries {
            guard let leftEntry = entry.left, let rightEntry = entry.right,
                  !leftEntry.isDirectory, !rightEntry.isDirectory else {
                results.append(entry)
                continue
            }
            let status = try fileStatus(
                leftEntry,
                rightEntry,
                comparison: comparison,
                tolerance: tolerance,
                believesClock: believesClock,
                contentsEqual: contentsEqual
            )
            guard status != .identical || includingIdentical else { continue }
            results.append(SyncEntry(
                relativePath: entry.relativePath,
                name: entry.name,
                left: leftEntry,
                right: rightEntry,
                status: status
            ))
        }
        return results
    }
}

extension DirectorySync {
    /// Whether deciding this same-named pair under ``SyncComparison/content`` reads their bytes.
    ///
    /// The one definition of "this pair costs a read", shared by the engine's classification and by
    /// the gesture's plan — see ``contentCandidates(in:)``.
    static func contentReadsBytes(_ left: FileEntry, _ right: FileEntry) -> Bool {
        left.kind == .file && right.kind == .file && left.byteSize == right.byteSize
    }
}
