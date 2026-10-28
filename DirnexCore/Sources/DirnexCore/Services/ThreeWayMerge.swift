import Foundation

/// Two edits of one text, merged against the version both started from (PLAN.md §M34).
///
/// Each side is compared with the base, and the two lists of changes are walked together the way
/// `git merge-file --diff3` walks them (xdiff's `xdl_do_merge`, read against git 2.54 and held to
/// its output by `ThreeWayMergeGitTests`):
/// - a change only one side made is taken from that side;
/// - the same base lines replaced by the same lines on both sides is one change, taken once;
/// - changes that overlap, or touch with no unchanged base line between them, are a conflict, and
///   so are two insertions at one place. A conflict takes in every change that touches it, on
///   either side, so one unchanged base line between two changes is what lets both merge.
///
/// A conflict's first and last lines, where both sides have them, then move out of it as
/// `--zdiff3` moves them, so taking both sides does not repeat them. Its base range stays whole,
/// since that is still what both sides replaced. git's default style does more, joining conflicts
/// a few lines apart, and is not the one matched.
///
/// No ignore option reaches a merge. Under `-w` a whitespace edit on one side would read as no
/// edit, and the merge would drop it without a word.
public struct ThreeWayMerge: Sendable, Equatable {
    /// What happened to one stretch of the three texts.
    public enum Kind: Sendable, Equatable {
        /// Neither side changed these lines: all three versions say the same.
        case unchanged
        /// Only yours changed them, so the merge takes yours. Theirs says what the base says.
        case yours
        /// Only theirs changed them, so the merge takes theirs. Yours says what the base says.
        case theirs
        /// Both sides say the same here and the base says something else: one change made on both
        /// sides, or the lines a conflict's two sides share at its edges. The merge takes them once.
        case same
        /// Both sides changed these lines, differently. Nothing is merged until someone chooses.
        case conflict
    }

    /// One stretch of the merge, as line indices into each of the three texts. The regions tile all
    /// three in order: each starts where the one before it ended, on every side.
    public struct Region: Sendable, Equatable {
        public let kind: Kind
        public let base: Range<Int>
        public let yours: Range<Int>
        public let theirs: Range<Int>

        public init(kind: Kind, base: Range<Int>, yours: Range<Int>, theirs: Range<Int>) {
            self.kind = kind
            self.base = base
            self.yours = yours
            self.theirs = theirs
        }
    }

    public let regions: [Region]

    /// How many conflicts are waiting for a choice.
    public var conflictCount: Int { regions.count(where: { $0.kind == .conflict }) }
    /// Whether every change merged on its own.
    public var isClean: Bool { !regions.contains { $0.kind == .conflict } }

    /// Merge `yours` and `theirs`, each an edit of `base`.
    ///
    /// Blocking and CPU-bound, as `LineDiff` is; call it off the main thread.
    public static func merge(
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine]
    ) -> ThreeWayMerge {
        merge(base: base, yours: yours, theirs: theirs, options: LineDiffOptions())
    }

    /// The merged text, each region from the side that changed it, or `nil` while a conflict is
    /// open. `yours` and `theirs` are the texts this merge was made from.
    public func mergedLines(yours: [TextLine], theirs: [TextLine]) -> [TextLine]? {
        guard isClean else { return nil }
        return regions.flatMap { region in
            region.kind == .theirs ? theirs[region.theirs] : yours[region.yours]
        }
    }

    /// Merge with the two comparisons made as `options` and `placement` say. Only `isMinimal`
    /// may differ from the defaults, which tests set to match `--diff-algorithm=minimal`.
    static func merge(
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine],
        options: LineDiffOptions,
        placement: ChangeSliding.Placement = .lowest,
        trimsConflicts: Bool = true
    ) -> ThreeWayMerge {
        let options = LineDiffOptions(isMinimal: options.isMinimal)
        return merge(
            base: base,
            yours: yours,
            theirs: theirs,
            yoursChanges: LineDiff.compare(base, yours, options: options, placement: placement)
                .changes,
            theirsChanges: LineDiff.compare(base, theirs, options: options, placement: placement)
                .changes,
            trimsConflicts: trimsConflicts
        )
    }
}
