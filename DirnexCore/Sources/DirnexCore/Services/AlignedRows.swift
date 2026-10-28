import Foundation

/// One row of a side-by-side comparison: a line on each side, or a line facing a gap (PLAN.md §M31
/// Slice 2).
///
/// Rows are what keeps the two panes level. Both sides have the same number of rows, so row `n` sits
/// at the same height in each pane and they scroll as one. A gap stands where one side has nothing
/// to put opposite the other's line.
public struct AlignedRow: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The two lines match, under the comparison's options.
        case same
        /// A line on each side, and they differ.
        case changed
        /// A line only the left has, facing a gap.
        case removed
        /// A line only the right has, facing a gap.
        case inserted
    }

    public let kind: Kind
    /// Line indices into each side, `nil` for a gap. The line number shown is the index plus one.
    public let left: Int?
    public let right: Int?
    /// For a changed row whose lines are alike, what differs inside them. `nil` on every other row,
    /// and on a changed row whose two lines have little in common, where the whole line is the
    /// difference.
    public let inline: InlineDifference?
    /// Whether the two lines end differently: CRLF against LF, or one without a final newline. It is
    /// the one difference no character on screen can show.
    public let lineEndingsDiffer: Bool

    public init(
        kind: Kind,
        left: Int?,
        right: Int?,
        inline: InlineDifference? = nil,
        lineEndingsDiffer: Bool = false
    ) {
        self.kind = kind
        self.left = left
        self.right = right
        self.inline = inline
        self.lineEndingsDiffer = lineEndingsDiffer
    }
}

/// Laying the lines of a comparison out as rows.
///
/// A changed block is laid out by pairing its alike lines first: each line on the left is matched
/// with at most one alike line on the right, in order, choosing the pairs that are most alike in
/// total (`LineFingerprint`). A paired row gets its inline differences. The lines between two pairs
/// go side by side from the top, and whatever one side has left over faces a gap. So a block that
/// gained a comment line above a changed call shows the comment against a gap and the two calls on
/// one row, where pairing from the top would set the comment against the old call.
enum RowAlignment {
    /// Above this many candidate pairs in one block, pairing compares only the lines that sit at the
    /// same depth in the block, which keeps a rewritten file from costing a quadratic amount of work.
    static let maximumPairingWork = 10000

    struct Layout {
        var rows: [AlignedRow] = []
        /// The rows of each change, in the order of `LineDiff.changes`.
        var changeRows: [Range<Int>] = []
    }

    static func layout(
        left: [TextLine],
        right: [TextLine],
        diff: LineDiff,
        options: LineDiffOptions
    ) -> Layout {
        var layout = Layout()
        layout.rows.reserveCapacity(max(left.count, right.count) + diff.changes.count)
        var leftIndex = 0
        var rightIndex = 0
        func appendSame(until leftEnd: Int) {
            while leftIndex < leftEnd {
                layout.rows.append(AlignedRow(
                    kind: .same,
                    left: leftIndex,
                    right: rightIndex,
                    lineEndingsDiffer: left[leftIndex].terminator != right[rightIndex].terminator
                ))
                leftIndex += 1
                rightIndex += 1
            }
        }
        for change in diff.changes {
            appendSame(until: change.left.lowerBound)
            let first = layout.rows.count
            layout.rows += blockRows(
                left: change.left.map { ($0, left[$0]) },
                right: change.right.map { ($0, right[$0]) },
                options: options
            )
            layout.changeRows.append(first..<layout.rows.count)
            leftIndex = change.left.upperBound
            rightIndex = change.right.upperBound
        }
        appendSame(until: left.count)
        return layout
    }

    /// The rows of one changed block.
    static func blockRows(
        left: [(index: Int, line: TextLine)],
        right: [(index: Int, line: TextLine)],
        options: LineDiffOptions
    ) -> [AlignedRow] {
        let pairs = alikePairs(left.map(\.line), right.map(\.line), options: options)
        var rows: [AlignedRow] = []
        var leftNext = 0
        var rightNext = 0
        for pair in pairs + [(left.count, right.count)] {
            // The lines between the previous pair and this one, side by side from the top.
            let leftGap = left[leftNext..<pair.0]
            let rightGap = right[rightNext..<pair.1]
            for offset in 0..<max(leftGap.count, rightGap.count) {
                let leftLine = offset < leftGap.count ? leftGap[leftGap.startIndex + offset] : nil
                let rightLine = offset < rightGap.count ? rightGap[rightGap.startIndex + offset] : nil
                rows.append(row(leftLine, rightLine, inline: nil))
            }
            guard pair.0 < left.count else { break }
            let leftLine = left[pair.0]
            let rightLine = right[pair.1]
            let inline = InlineDiff.difference(
                leftLine.line.content,
                rightLine.line.content,
                options: options
            )
            rows.append(row(leftLine, rightLine, inline: inline))
            leftNext = pair.0 + 1
            rightNext = pair.1 + 1
        }
        return rows
    }

    private static func row(
        _ left: (index: Int, line: TextLine)?,
        _ right: (index: Int, line: TextLine)?,
        inline: InlineDifference?
    ) -> AlignedRow {
        switch (left, right) {
        case let (left?, right?):
            AlignedRow(
                kind: .changed,
                left: left.index,
                right: right.index,
                inline: inline,
                lineEndingsDiffer: left.line.terminator != right.line.terminator
            )
        case let (left?, nil):
            AlignedRow(kind: .removed, left: left.index, right: nil)
        case let (nil, right?):
            AlignedRow(kind: .inserted, left: nil, right: right.index)
        case (nil, nil):
            preconditionFailure("a row needs a line on at least one side")
        }
    }

    /// Which lines of a block to put on one row: positions into `left` and `right`, in order.
    static func alikePairs(
        _ left: [TextLine],
        _ right: [TextLine],
        options: LineDiffOptions
    ) -> [(Int, Int)] {
        guard !left.isEmpty, !right.isEmpty else { return [] }
        let leftPrints = left.map { LineFingerprint($0.content, ignoresCase: options.ignoresCase) }
        let rightPrints = right.map { LineFingerprint($0.content, ignoresCase: options.ignoresCase) }
        let threshold = LineFingerprint.pairingThreshold
        guard left.count * right.count <= maximumPairingWork else {
            return (0..<min(left.count, right.count)).filter {
                leftPrints[$0].similarity(to: rightPrints[$0]) >= threshold
            }.map { ($0, $0) }
        }
        // The most alike set of pairs that keeps both sides in order: a table of the best total for
        // each prefix of the two sides, read back from the far corner.
        let width = right.count + 1
        var best = Array(repeating: 0.0, count: (left.count + 1) * width)
        var similarity = Array(repeating: 0.0, count: left.count * right.count)
        for i in 1...left.count {
            for j in 1...right.count {
                let alike = leftPrints[i - 1].similarity(to: rightPrints[j - 1])
                similarity[(i - 1) * right.count + j - 1] = alike
                var total = max(best[(i - 1) * width + j], best[i * width + j - 1])
                if alike >= threshold {
                    total = max(total, best[(i - 1) * width + j - 1] + alike)
                }
                best[i * width + j] = total
            }
        }
        var pairs: [(Int, Int)] = []
        var i = left.count
        var j = right.count
        while i > 0, j > 0 {
            let alike = similarity[(i - 1) * right.count + j - 1]
            if alike >= threshold, best[i * width + j] == best[(i - 1) * width + j - 1] + alike {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if best[i * width + j] == best[(i - 1) * width + j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }
}
