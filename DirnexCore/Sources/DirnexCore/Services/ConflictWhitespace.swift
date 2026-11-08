import Foundation

/// What whitespace explains in one conflict of a merge, read off the regions once they are made
/// (PLAN.md §M37 Slice 5).
///
/// git's `-Xignore-space-change` and `-Xignore-all-space` settle a conflict like this by dropping one
/// side's whitespace edit without a word: probed 2026-11-08 with git 2.54, a re-indent, a stripped
/// trailing space and a CRLF conversion each vanished from the result. So no ignore option reaches
/// `ThreeWayMerge`. Its regions stay byte-exact, the conflict stays a conflict, and this only labels
/// it and offers one more take. Save still waits for a choice, so a whitespace edit is either kept or
/// was chosen against.
///
/// Whitespace is git's `-w`: spaces, tabs and the line ending (`LineDiffOptions.Whitespace.ignoreAll`),
/// compared line for line, so a blank line added or removed is not whitespace.
///
/// A conflict is read together with the lines `--zdiff3`'s trimming moved out of it, the regions of
/// both sides' shared lines with no base lines just before and after it: its base range is still the
/// whole stretch both sides replaced, and those lines are part of what each side put there.
public struct ConflictWhitespace: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Yours' lines here are the base's with only their whitespace changed, so theirs made the
        /// only other edit.
        case yoursOnlyWhitespace
        /// Theirs' lines here are the base's with only their whitespace changed.
        case theirsOnlyWhitespace
        /// The two sides are the same lines but for whitespace: both changed only whitespace, or
        /// both made one edit, spaced differently.
        case sidesDifferOnlyInWhitespace
    }

    public let kind: Kind
    /// What `TextMerge.Choice.editWithWhitespace` puts in the result: the side with the edit, each
    /// line given the whitespace the other side gave the base line it came from (`WhitespaceCarry`),
    /// one line for each of that side's. `nil` where the take is not offered: the sides differ only
    /// in whitespace, some of the whitespace cannot be carried, or carrying it changes nothing.
    public let combined: [TextLine]?

    public init(kind: Kind, combined: [TextLine]?) {
        self.kind = kind
        self.combined = combined
    }

    /// The side whose text `combined` keeps, `nil` where both sides are the same text.
    public var editSide: MergeRow.Column? {
        switch kind {
        case .yoursOnlyWhitespace: .theirs
        case .theirsOnlyWhitespace: .yours
        case .sidesDifferOnlyInWhitespace: nil
        }
    }

    /// What whitespace explains in each of `merge`'s conflicts, in order, `nil` where it explains
    /// nothing. Blocking and CPU-bound, as the merge is.
    static func explain(
        _ merge: ThreeWayMerge,
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine]
    ) -> [ConflictWhitespace?] {
        merge.regions.indices.filter { merge.regions[$0].kind == .conflict }.map { index in
            explain(region: index, of: merge, base: base, yours: yours, theirs: theirs)
        }
    }

    /// What whitespace explains in the conflict at `merge.regions[index]`.
    static func explain(
        region index: Int,
        of merge: ThreeWayMerge,
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine]
    ) -> ConflictWhitespace? {
        let regions = merge.regions
        let conflict = regions[index]
        // The shared lines the trimming moved out, on each side of the conflict.
        let before = index > 0 && isTrimmed(regions[index - 1], at: conflict.base.lowerBound)
            ? regions[index - 1].yours.count : 0
        let after = index + 1 < regions.count && isTrimmed(
            regions[index + 1],
            at: conflict.base.upperBound
        )
            ? regions[index + 1].yours.count : 0
        func whole(_ range: Range<Int>) -> Range<Int> {
            range.lowerBound - before..<range.upperBound + after
        }
        let baseLines = Array(base[conflict.base])
        let yoursLines = Array(yours[whole(conflict.yours)])
        let theirsLines = Array(theirs[whole(conflict.theirs)])
        let kind: Kind
        let spacing: [TextLine]
        let edit: [TextLine]
        if sameButForWhitespace(yoursLines, theirsLines) {
            return ConflictWhitespace(kind: .sidesDifferOnlyInWhitespace, combined: nil)
        } else if sameButForWhitespace(yoursLines, baseLines) {
            (kind, spacing, edit) = (.yoursOnlyWhitespace, yoursLines, theirsLines)
        } else if sameButForWhitespace(theirsLines, baseLines) {
            (kind, spacing, edit) = (.theirsOnlyWhitespace, theirsLines, yoursLines)
        } else {
            return nil
        }
        let own = before..<edit.count - after
        let combined = WhitespaceCarry.carry(spacing: spacing, base: baseLines, onto: edit)
            .map { Array($0[own]) }
            .flatMap { lines in sameBytes(lines, edit[own]) ? nil : lines }
        return ConflictWhitespace(kind: kind, combined: combined)
    }

    /// Whether `region` is shared lines the trimming moved out of a conflict whose base range starts
    /// or ends at `base`.
    private static func isTrimmed(_ region: ThreeWayMerge.Region, at base: Int) -> Bool {
        region.kind == .same && region.base == base..<base
    }

    /// Whether two runs of lines are the same, line for line, but for git's `-w` whitespace.
    static func sameButForWhitespace(_ lines: [TextLine], _ others: [TextLine]) -> Bool {
        let options = LineDiffOptions(whitespace: .ignoreAll)
        return lines.count == others.count
            && zip(lines, others).allSatisfy { options.key(for: $0) == options.key(for: $1) }
    }

    private static func sameBytes(_ lines: [TextLine], _ others: ArraySlice<TextLine>) -> Bool {
        lines.count == others.count && zip(lines, others).allSatisfy { line, other in
            line.terminator == other.terminator && line.content.utf8.elementsEqual(
                other.content.utf8
            )
        }
    }
}
