import Foundation

/// How two texts differ, line by line: the blocks of lines the left side has that the right side
/// replaces (PLAN.md §M31).
///
/// It is the engine under Dirnex's own compare window, and it answers the question git's
/// `diff --numstat` answers: which lines are removed and which inserted. Counts are checked against
/// `git diff --no-index --minimal` over a corpus of this repository's own files, so "changed" means
/// what it means to git, apart from the two departures `TextLines` and `LineDiffOptions` state.
public struct LineDiff: Sendable, Equatable {
    /// One block of difference: `left` is replaced by `right`. Either range may be empty, for a
    /// block that is only removed or only inserted, but never both. Ranges are line indices into
    /// the two inputs, and blocks come in order, separated by at least one unchanged line.
    public struct Change: Sendable, Equatable {
        public let left: Range<Int>
        public let right: Range<Int>

        public init(left: Range<Int>, right: Range<Int>) {
            self.left = left
            self.right = right
        }
    }

    public let changes: [Change]
    public let leftLineCount: Int
    public let rightLineCount: Int

    /// Whether no line differs under the options used. Two texts can be identical here and still
    /// differ as files: in their encoding, or in what the options overlooked.
    public var isIdentical: Bool { changes.isEmpty }
    /// Lines only the left side has: git's "deleted" count.
    public var removedLineCount: Int { changes.reduce(0) { $0 + $1.left.count } }
    /// Lines only the right side has: git's "added" count.
    public var insertedLineCount: Int { changes.reduce(0) { $0 + $1.right.count } }

    /// Compare two texts, split into lines by `TextLines`.
    public static func compare(
        _ left: String,
        _ right: String,
        options: LineDiffOptions = LineDiffOptions()
    ) -> LineDiff {
        compare(TextLines.split(left), TextLines.split(right), options: options)
    }

    /// Compare two sequences of lines.
    ///
    /// The search runs on interned line identities, and before it starts every line that appears
    /// on only one side is set aside as changed. Such a line can never be part of a common
    /// subsequence, so setting it aside cannot change the answer, and it is most of the work when
    /// two files have little in common.
    ///
    /// Blocking and CPU-bound; call it off the main thread.
    public static func compare(
        _ left: [TextLine],
        _ right: [TextLine],
        options: LineDiffOptions = LineDiffOptions()
    ) -> LineDiff {
        compare(left, right, options: options, placement: .readable)
    }

    /// Compare two sequences of lines, placing each block that could sit in more than one place
    /// as `placement` says.
    static func compare(
        _ left: [TextLine],
        _ right: [TextLine],
        options: LineDiffOptions,
        placement: ChangeSliding.Placement
    ) -> LineDiff {
        var identities = LineIdentities(options: options)
        let leftIDs = left.map { identities.identity(of: $0) }
        let rightIDs = right.map { identities.identity(of: $0) }

        let onLeft = identities.occurrences(in: leftIDs)
        let onRight = identities.occurrences(in: rightIDs)
        let leftKept = leftIDs.indices.filter { onRight[Int(leftIDs[$0])] }
        let rightKept = rightIDs.indices.filter { onLeft[Int(rightIDs[$0])] }

        let costLimit = options.isMinimal
            ? Int.max
            : MyersDiff.defaultCostLimit(leftCount: leftKept.count, rightCount: rightKept.count)
        let kept = MyersDiff.changes(
            leftKept.map { leftIDs[$0] },
            rightKept.map { rightIDs[$0] },
            costLimit: costLimit
        )
        var leftSide = ChangeSliding.Side(
            ids: leftIDs,
            changed: Array(repeating: true, count: left.count),
            shapes: left.map { ChangeSliding.LineShape($0.content) }
        )
        for (position, index) in leftKept.enumerated() {
            leftSide.changed[index] = kept.left[position]
        }
        var rightSide = ChangeSliding.Side(
            ids: rightIDs,
            changed: Array(repeating: true, count: right.count),
            shapes: right.map { ChangeSliding.LineShape($0.content) }
        )
        for (position, index) in rightKept.enumerated() {
            rightSide.changed[index] = kept.right[position]
        }
        ChangeSliding.slide(&leftSide, &rightSide, placement: placement)
        return LineDiff(
            changes: blocks(leftSide.changed, rightSide.changed),
            leftLineCount: left.count,
            rightLineCount: right.count
        )
    }

    /// Runs of changed lines on each side, paired in order. The unchanged lines are the common
    /// subsequence, so there are as many on one side as on the other and they pair one to one.
    static func blocks(_ leftChanged: [Bool], _ rightChanged: [Bool]) -> [Change] {
        var changes: [Change] = []
        var leftIndex = 0
        var rightIndex = 0
        while leftIndex < leftChanged.count || rightIndex < rightChanged.count {
            let leftStart = leftIndex
            let rightStart = rightIndex
            while leftIndex < leftChanged.count, leftChanged[leftIndex] {
                leftIndex += 1
            }
            while rightIndex < rightChanged.count, rightChanged[rightIndex] {
                rightIndex += 1
            }
            if leftIndex > leftStart || rightIndex > rightStart {
                changes.append(Change(left: leftStart..<leftIndex, right: rightStart..<rightIndex))
                continue
            }
            // An unchanged line on each side, matched to each other. A side that has run out while
            // the other has an unchanged line left would be a broken subsequence; stop rather than
            // loop, and report the rest as one block.
            guard leftIndex < leftChanged.count, rightIndex < rightChanged.count else {
                changes.append(Change(
                    left: leftIndex..<leftChanged.count,
                    right: rightIndex..<rightChanged.count
                ))
                break
            }
            leftIndex += 1
            rightIndex += 1
        }
        return changes
    }
}

/// Small integers standing for distinct lines, so the search compares one integer per step.
private struct LineIdentities {
    let options: LineDiffOptions
    private var table: [[UInt8]: Int32] = [:]

    init(options: LineDiffOptions) {
        self.options = options
    }

    mutating func identity(of line: TextLine) -> Int32 {
        let key = options.key(for: line)
        if let known = table[key] {
            return known
        }
        let identity = Int32(table.count)
        table[key] = identity
        return identity
    }

    /// Which identities appear at least once in `ids`.
    func occurrences(in ids: [Int32]) -> [Bool] {
        var seen = Array(repeating: false, count: table.count)
        for id in ids {
            seen[Int(id)] = true
        }
        return seen
    }
}
