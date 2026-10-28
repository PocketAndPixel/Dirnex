import Foundation

/// Everything the merge window shows for three versions of one text, and the result being built
/// from them (PLAN.md §M34 Slice 2).
///
/// The result starts as yours' document with every region merged: each one from the side that
/// changed it, and nothing yet where a conflict is. So it keeps yours' encoding, byte-order mark
/// and line endings, and `result.isEdited` says whether saving it would change yours' file. A
/// conflict gets its lines when someone chooses for it, and every choice is a `LineEdit` on the
/// result, as M33's copies are. `apply(_:)` returns the step that undoes it, so undo and redo are
/// one operation.
///
/// Lines are taken as their side has them, endings included, as git takes them. The one exception
/// is taking both sides: when the first side's lines end with its file's last line, which has no
/// line break, that line gets the result's common one, or the second side's lines would join it.
public struct TextMerge: Sendable {
    /// What a conflict takes.
    public enum Choice: Sendable, Equatable, CaseIterable {
        case yours
        case theirs
        /// Both: yours' lines, then theirs'.
        case yoursThenTheirs
        /// Both: theirs' lines, then yours'.
        case theirsThenYours
    }

    /// One change to the result: conflict `conflict` takes `choice`, or is open again for `nil`.
    public struct Step: Sendable, Equatable {
        public let conflict: Int
        public let choice: Choice?

        public init(conflict: Int, choice: Choice?) {
            self.conflict = conflict
            self.choice = choice
        }
    }

    public let base: ComparedDocument
    public let yours: ComparedDocument
    public let theirs: ComparedDocument
    public let merge: ThreeWayMerge
    /// The merged text as it stands.
    public private(set) var result: ComparedDocument
    /// What each conflict takes, in order, `nil` while it is open.
    public private(set) var choices: [Choice?]
    /// Every column's rows, level with each other (`MergeRow`).
    public private(set) var rows: [MergeRow] = []
    /// The rows of each conflict, in order, for moving from one conflict to the next.
    public private(set) var conflictRows: [Range<Int>] = []

    /// The region of each conflict, in order.
    private let conflictRegions: [Int]
    private let templates: [MergeRowLayout.Template]
    /// How many result lines each region holds now.
    private var resultCounts: [Int]

    /// Merge `yours` and `theirs`, each an edit of `base`. Blocking and CPU-bound, as `LineDiff` is;
    /// call it off the main thread.
    public init(base: ComparedDocument, yours: ComparedDocument, theirs: ComparedDocument) {
        self.init(
            base: base,
            yours: yours,
            theirs: theirs,
            merge: ThreeWayMerge.merge(base: base.lines, yours: yours.lines, theirs: theirs.lines)
        )
    }

    init(
        base: ComparedDocument,
        yours: ComparedDocument,
        theirs: ComparedDocument,
        merge: ThreeWayMerge
    ) {
        self.base = base
        self.yours = yours
        self.theirs = theirs
        self.merge = merge
        conflictRegions = merge.regions.indices.filter { merge.regions[$0].kind == .conflict }
        choices = Array(repeating: nil, count: conflictRegions.count)
        templates = MergeRowLayout.templates(
            merge,
            base: base.lines,
            yours: yours.lines,
            theirs: theirs.lines
        )
        let merged = merge.regions.map { region in
            switch region.kind {
            case .conflict: [] as ArraySlice<TextLine>
            case .theirs: theirs.lines[region.theirs]
            case .unchanged, .yours, .same: yours.lines[region.yours]
            }
        }
        resultCounts = merged.map(\.count)
        var result = yours
        result.apply(LineEdit(range: 0..<yours.lines.count, replacement: Array(merged.joined())))
        self.result = result
        layOut()
    }

    /// How many conflicts are still open.
    public var openConflictCount: Int { choices.count(where: { $0 == nil }) }
    /// Whether every conflict has a choice, so the result can be saved.
    public var isResolved: Bool { !choices.contains(nil) }

    /// Make `step`'s choice, and return the step that undoes it. A step that changes nothing
    /// returns itself.
    @discardableResult
    public mutating func apply(_ step: Step) -> Step {
        let previous = choices[step.conflict]
        guard previous != step.choice else { return step }
        let region = conflictRegions[step.conflict]
        let start = resultCounts[..<region].reduce(0, +)
        let replacement = lines(for: step.choice, of: merge.regions[region])
        result.apply(LineEdit(range: start..<start + resultCounts[region], replacement: replacement))
        resultCounts[region] = replacement.count
        choices[step.conflict] = step.choice
        layOut()
        return Step(conflict: step.conflict, choice: previous)
    }

    /// One column as the text its pane holds, a gap for every row it has no line on.
    public func paneText(for column: MergeRow.Column) -> ComparisonPaneText {
        let lines = switch column {
        case .yours: yours.lines
        case .result: result.lines
        case .theirs: theirs.lines
        case .base: base.lines
        }
        return ComparisonPaneText(lines: lines, rows: rows.map { $0.line(in: column) })
    }

    // MARK: - Moving between conflicts

    /// The first conflict that starts below `row`, or `nil` past the last one. Pass `-1` for the
    /// first of all, and `onlyOpen` to pass over those already chosen.
    public func conflict(after row: Int, onlyOpen: Bool = false) -> Int? {
        conflictRows.indices.first { conflictRows[$0].lowerBound > row && isWanted($0, onlyOpen) }
    }

    /// The last conflict that starts above `row`, or `nil` before the first one.
    public func conflict(before row: Int, onlyOpen: Bool = false) -> Int? {
        conflictRows.indices.last { conflictRows[$0].lowerBound < row && isWanted($0, onlyOpen) }
    }

    /// The conflict holding `row`, for "conflict 2 of 5".
    public func conflict(containing row: Int) -> Int? {
        conflictRows.firstIndex { $0.contains(row) }
    }

    private func isWanted(_ conflict: Int, _ onlyOpen: Bool) -> Bool {
        !onlyOpen || choices[conflict] == nil
    }

    // MARK: - The result's lines

    /// What a conflict puts in the result for `choice`.
    private func lines(for choice: Choice?, of region: ThreeWayMerge.Region) -> [TextLine] {
        let yoursLines = Array(yours.lines[region.yours])
        let theirsLines = Array(theirs.lines[region.theirs])
        switch choice {
        case nil: return []
        case .yours: return yoursLines
        case .theirs: return theirsLines
        case .yoursThenTheirs: return joined(yoursLines, theirsLines)
        case .theirsThenYours: return joined(theirsLines, yoursLines)
        }
    }

    /// `first` then `second`, with a line break for `first`'s last line when it has none.
    private func joined(_ first: [TextLine], _ second: [TextLine]) -> [TextLine] {
        guard let last = first.last, last.terminator == .none, !second.isEmpty else {
            return first + second
        }
        let ending = result.commonLineEnding ?? theirs.commonLineEnding ?? .lf
        return first.dropLast() + [TextLine(content: last.content, terminator: ending)] + second
    }

    // MARK: - Rows

    private mutating func layOut() {
        var rows: [MergeRow] = []
        var conflictRows: [Range<Int>] = []
        var resultStart = 0
        var conflict = 0
        for (region, template) in templates.enumerated() {
            let isConflict = template.resultRepeats == nil
            let first = rows.count
            rows += MergeRowLayout.rows(
                of: template,
                region: region,
                resultStart: resultStart,
                choice: isConflict ? choices[conflict] : nil
            )
            if isConflict {
                conflictRows.append(first..<rows.count)
                conflict += 1
            }
            resultStart += resultCounts[region]
        }
        self.rows = rows
        self.conflictRows = conflictRows
    }
}
