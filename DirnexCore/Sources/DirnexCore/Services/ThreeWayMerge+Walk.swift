import Foundation

/// git's walk over the two comparisons, kept apart from the model it fills (PLAN.md §M34 Slice 1).
///
/// The arithmetic is xdiff's `xdl_do_merge` and `xdl_append_merge` kept as they are, rather than
/// restated, so the two cannot drift; `ThreeWayMergeGitTests` holds the result to git's own output
/// byte for byte.
extension ThreeWayMerge {
    /// Merge from the two comparisons already made: `yoursChanges` from `base` to `yours`, and
    /// `theirsChanges` from `base` to `theirs`, each with the base on the left. Without
    /// `trimsConflicts` the regions are `--diff3`'s exactly, which is what the tests hold them to.
    static func merge(
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine],
        yoursChanges: [LineDiff.Change],
        theirsChanges: [LineDiff.Change],
        trimsConflicts: Bool = true
    ) -> ThreeWayMerge {
        let walked = walk(yoursChanges, theirsChanges) { yoursRange, theirsRange in
            yoursRange.count == theirsRange.count
                && zip(yoursRange, theirsRange).allSatisfy { isSame(yours[$0], theirs[$1]) }
        }
        var spans: [Span] = []
        for span in walked {
            guard trimsConflicts, span.kind == .conflict else {
                spans.append(span)
                continue
            }
            spans += trimmed(span, yours: yours, theirs: theirs)
        }
        return ThreeWayMerge(regions: tiled(
            spans,
            baseCount: base.count,
            yoursCount: yours.count,
            theirsCount: theirs.count
        ))
    }

    /// A region as git's merge keeps it while walking: where it starts on each side, and how many
    /// lines it has there.
    private struct Span {
        var kind: Kind
        var base: Int
        var baseCount: Int
        var yours: Int
        var yoursCount: Int
        var theirs: Int
        var theirsCount: Int

        var baseEnd: Int { base + baseCount }
        var yoursEnd: Int { yours + yoursCount }
        var theirsEnd: Int { theirs + theirsCount }
    }

    /// The regions where a change is, in order: git's walk, with its arithmetic kept as it is so the
    /// two cannot drift. Each side's changes come with the base on the left. Every stretch outside
    /// the regions returned is unchanged on both sides.
    private static func walk(
        _ yoursChanges: [LineDiff.Change],
        _ theirsChanges: [LineDiff.Change],
        isSameChange: (Range<Int>, Range<Int>) -> Bool
    ) -> [Span] {
        var spans: [Span] = []
        // git records no region for a change both sides made, and copies it from yours with the
        // unchanged lines. Kept apart here, so the joining below never sees one.
        var same: [Span] = []
        var yoursIndex = 0
        var theirsIndex = 0
        while yoursIndex < yoursChanges.count, theirsIndex < theirsChanges.count {
            let mine = yoursChanges[yoursIndex]
            let other = theirsChanges[theirsIndex]
            if mine.left.upperBound < other.left.lowerBound {
                // Theirs says what the base says here, shifted by theirs' changes so far.
                let theirsStart = mine.left.lowerBound + other.right.lowerBound
                    - other.left.lowerBound
                append(Span(
                    kind: .yours,
                    base: mine.left.lowerBound, baseCount: mine.left.count,
                    yours: mine.right.lowerBound, yoursCount: mine.right.count,
                    theirs: theirsStart, theirsCount: mine.left.count
                ), to: &spans)
                yoursIndex += 1
                continue
            }
            if other.left.upperBound < mine.left.lowerBound {
                let yoursStart = other.left.lowerBound + mine.right.lowerBound
                    - mine.left.lowerBound
                append(Span(
                    kind: .theirs,
                    base: other.left.lowerBound, baseCount: other.left.count,
                    yours: yoursStart, yoursCount: other.left.count,
                    theirs: other.right.lowerBound, theirsCount: other.right.count
                ), to: &spans)
                theirsIndex += 1
                continue
            }
            if mine.left == other.left, isSameChange(mine.right, other.right) {
                same.append(Span(
                    kind: .same,
                    base: mine.left.lowerBound, baseCount: mine.left.count,
                    yours: mine.right.lowerBound, yoursCount: mine.right.count,
                    theirs: other.right.lowerBound, theirsCount: other.right.count
                ))
            } else {
                append(conflict(mine, other), to: &spans)
            }
            // Step past whichever change ends first in the base, or both.
            let mineEnd = mine.left.upperBound
            let otherEnd = other.left.upperBound
            if mineEnd >= otherEnd {
                theirsIndex += 1
            }
            if otherEnd >= mineEnd {
                yoursIndex += 1
            }
        }
        let theirsShift = theirsChanges.reduce(0) { $0 + $1.right.count - $1.left.count }
        for mine in yoursChanges[yoursIndex...] {
            append(Span(
                kind: .yours,
                base: mine.left.lowerBound, baseCount: mine.left.count,
                yours: mine.right.lowerBound, yoursCount: mine.right.count,
                theirs: mine.left.lowerBound + theirsShift, theirsCount: mine.left.count
            ), to: &spans)
        }
        let yoursShift = yoursChanges.reduce(0) { $0 + $1.right.count - $1.left.count }
        for other in theirsChanges[theirsIndex...] {
            append(Span(
                kind: .theirs,
                base: other.left.lowerBound, baseCount: other.left.count,
                yours: other.left.lowerBound + yoursShift, yoursCount: other.left.count,
                theirs: other.right.lowerBound, theirsCount: other.right.count
            ), to: &spans)
        }
        return (spans + same).sorted { $0.base < $1.base }
    }

    /// The conflict between two changes that overlap or touch: from the earlier start to the later
    /// end in the base, and on each side the change plus the unchanged lines that reach to there.
    private static func conflict(_ mine: LineDiff.Change, _ other: LineDiff.Change) -> Span {
        let startOffset = mine.left.lowerBound - other.left.lowerBound
        let endOffset = mine.left.upperBound - other.left.upperBound
        var base = mine.left.lowerBound
        var yours = mine.right.lowerBound
        var theirs = other.right.lowerBound
        if startOffset > 0 {
            base -= startOffset
            yours -= startOffset
        } else {
            theirs += startOffset
        }
        var baseCount = mine.left.upperBound - base
        var yoursCount = mine.right.upperBound - yours
        var theirsCount = other.right.upperBound - theirs
        if endOffset < 0 {
            baseCount -= endOffset
            yoursCount -= endOffset
        } else {
            theirsCount += endOffset
        }
        return Span(
            kind: .conflict,
            base: base, baseCount: baseCount,
            yours: yours, yoursCount: yoursCount,
            theirs: theirs, theirsCount: theirsCount
        )
    }

    /// Add `span` after the last region, or join the two when they touch on either side. Two
    /// regions of different kinds joined are a conflict.
    private static func append(_ span: Span, to spans: inout [Span]) {
        guard var last = spans.last,
              span.yours <= last.yoursEnd || span.theirs <= last.theirsEnd else {
            spans.append(span)
            return
        }
        if span.kind != last.kind {
            last.kind = .conflict
        }
        last.baseCount = span.baseEnd - last.base
        last.yoursCount = span.yoursEnd - last.yours
        last.theirsCount = span.theirsEnd - last.theirs
        spans[spans.count - 1] = last
    }

    /// A conflict without the lines both sides share at its start and at its end, which become
    /// regions of their own with no base lines, before and after it.
    ///
    /// A conflict both of whose sides are the same lines is no conflict, and merges as one change
    /// made on both sides. It comes from how the two comparisons aligned the same edit, such as each
    /// side's deleting a different one of two equal lines, which leaves both sides with one. git's
    /// `--zdiff3` keeps it, with nothing on either side of the markers once trimmed; there is
    /// nothing to choose.
    private static func trimmed(_ span: Span, yours: [TextLine], theirs: [TextLine]) -> [Span] {
        var conflict = span
        var leading = 0
        while conflict.yoursCount > 0, conflict.theirsCount > 0,
              isSame(yours[conflict.yours], theirs[conflict.theirs]) {
            conflict.yours += 1
            conflict.yoursCount -= 1
            conflict.theirs += 1
            conflict.theirsCount -= 1
            leading += 1
        }
        if conflict.yoursCount == 0, conflict.theirsCount == 0 {
            var same = span
            same.kind = .same
            return [same]
        }
        var trailing = 0
        while conflict.yoursCount > 0, conflict.theirsCount > 0,
              isSame(yours[conflict.yoursEnd - 1], theirs[conflict.theirsEnd - 1]) {
            conflict.yoursCount -= 1
            conflict.theirsCount -= 1
            trailing += 1
        }
        var spans: [Span] = []
        if leading > 0 {
            spans.append(Span(
                kind: .same,
                base: span.base, baseCount: 0,
                yours: span.yours, yoursCount: leading,
                theirs: span.theirs, theirsCount: leading
            ))
        }
        spans.append(conflict)
        if trailing > 0 {
            spans.append(Span(
                kind: .same,
                base: span.baseEnd, baseCount: 0,
                yours: conflict.yoursEnd, yoursCount: trailing,
                theirs: conflict.theirsEnd, theirsCount: trailing
            ))
        }
        return spans
    }

    /// The regions where something changed, with an unchanged region in every stretch between
    /// them, so the result covers all three texts.
    private static func tiled(
        _ spans: [Span],
        baseCount: Int,
        yoursCount: Int,
        theirsCount: Int
    ) -> [Region] {
        var regions: [Region] = []
        var base = 0
        var yours = 0
        var theirs = 0
        func unchanged(through span: Span) {
            guard span.base > base || span.yours > yours || span.theirs > theirs else { return }
            regions.append(Region(
                kind: .unchanged,
                base: base..<span.base,
                yours: yours..<span.yours,
                theirs: theirs..<span.theirs
            ))
        }
        for span in spans {
            unchanged(through: span)
            regions.append(Region(
                kind: span.kind,
                base: span.base..<span.baseEnd,
                yours: span.yours..<span.yoursEnd,
                theirs: span.theirs..<span.theirsEnd
            ))
            base = span.baseEnd
            yours = span.yoursEnd
            theirs = span.theirsEnd
        }
        unchanged(through: Span(
            kind: .unchanged,
            base: baseCount, baseCount: 0,
            yours: yoursCount, yoursCount: 0,
            theirs: theirsCount, theirsCount: 0
        ))
        return regions
    }

    /// Whether two lines are the same bytes, terminators included: the comparison `LineDiff` makes
    /// with no option set, never `String`'s canonical equivalence.
    private static func isSame(_ line: TextLine, _ other: TextLine) -> Bool {
        line.terminator == other.terminator && line.content.utf8.elementsEqual(other.content.utf8)
    }
}
