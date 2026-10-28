import Foundation

/// One row of the merge window: a line, or a gap, in each of its columns (PLAN.md §M34 Slice 2).
///
/// Rows keep the panes level, as `AlignedRow` does for two: every column has the same number of
/// rows, so row `n` sits at the same height in each. Each region of the merge starts on the same
/// row in every column, and the result's lines sit level with the lines they came from.
public struct MergeRow: Sendable, Equatable {
    /// The four texts a merge window can show.
    public enum Column: Sendable, CaseIterable {
        case yours
        case result
        case theirs
        /// Shown on request.
        case base
    }

    /// The region this row belongs to: an index into `ThreeWayMerge.regions`.
    public let region: Int
    /// Line indices into each text, `nil` for a gap. The line number shown is the index plus one.
    public let yours: Int?
    public let result: Int?
    public let theirs: Int?
    public let base: Int?

    public init(region: Int, yours: Int?, result: Int?, theirs: Int?, base: Int?) {
        self.region = region
        self.yours = yours
        self.result = result
        self.theirs = theirs
        self.base = base
    }

    /// The line this row shows in `column`, or `nil` for a gap.
    public func line(in column: Column) -> Int? {
        switch column {
        case .yours: yours
        case .result: result
        case .theirs: theirs
        case .base: base
        }
    }
}

/// Laying a merge's regions out as rows.
///
/// Each region is laid out once, and only the result column changes as conflicts are chosen:
/// - an unchanged region has a row per line, the same line in every column;
/// - a region one side changed puts that side's lines beside the base's, alike lines on one row as
///   the compare window pairs them (`RowAlignment`). The side that did not change repeats the base,
///   and the result repeats the side that did. The same change made on both sides is laid out the
///   same way, with both sides repeating it;
/// - a conflict puts yours beside theirs, alike lines on one row, and the base from its first row
///   down, with rows added below when it is longer. An open conflict has no result lines. One side
///   taken repeats that side's lines; both taken repeat the first side's, then put the second's on
///   the rows after its last, adding rows as they run out.
enum MergeRowLayout {
    /// One row of the three versions, before the result is filled in.
    struct VersionRow: Equatable {
        var yours: Int?
        var theirs: Int?
        var base: Int?
    }

    /// One region's rows, and which version the result repeats in a region that is not a conflict.
    struct Template {
        var rows: [VersionRow]
        /// `.yours` or `.theirs`; `nil` for a conflict, whose result depends on the choice.
        let resultRepeats: MergeRow.Column?
    }

    /// The template of every region of `merge`.
    static func templates(
        _ merge: ThreeWayMerge,
        base: [TextLine],
        yours: [TextLine],
        theirs: [TextLine]
    ) -> [Template] {
        merge.regions.map { region in
            func indexed(_ lines: [TextLine], _ range: Range<Int>) -> [(index: Int, line: TextLine)] {
                range.map { ($0, lines[$0]) }
            }
            /// `side`'s lines beside the base's, alike lines paired.
            func beside(_ side: [TextLine], _ range: Range<Int>) -> [AlignedRow] {
                RowAlignment.blockRows(
                    left: indexed(base, region.base),
                    right: indexed(side, range),
                    options: LineDiffOptions()
                )
            }
            /// The line of `range` at the position `index` has in `from`.
            func mirror(_ index: Int?, from: Range<Int>, into range: Range<Int>) -> Int? {
                index.map { range.lowerBound + $0 - from.lowerBound }
            }
            switch region.kind {
            case .unchanged:
                return Template(
                    rows: (0..<region.base.count).map { offset in
                        VersionRow(
                            yours: region.yours.lowerBound + offset,
                            theirs: region.theirs.lowerBound + offset,
                            base: region.base.lowerBound + offset
                        )
                    },
                    resultRepeats: .yours
                )
            case .yours:
                return Template(
                    rows: beside(yours, region.yours).map { row in
                        VersionRow(
                            yours: row.right,
                            theirs: mirror(row.left, from: region.base, into: region.theirs),
                            base: row.left
                        )
                    },
                    resultRepeats: .yours
                )
            case .theirs:
                return Template(
                    rows: beside(theirs, region.theirs).map { row in
                        VersionRow(
                            yours: mirror(row.left, from: region.base, into: region.yours),
                            theirs: row.right,
                            base: row.left
                        )
                    },
                    resultRepeats: .theirs
                )
            case .same:
                return Template(
                    rows: beside(yours, region.yours).map { row in
                        VersionRow(
                            yours: row.right,
                            theirs: mirror(row.right, from: region.yours, into: region.theirs),
                            base: row.left
                        )
                    },
                    resultRepeats: .yours
                )
            case .conflict:
                var rows = RowAlignment.blockRows(
                    left: indexed(yours, region.yours),
                    right: indexed(theirs, region.theirs),
                    options: LineDiffOptions()
                ).map { VersionRow(yours: $0.left, theirs: $0.right, base: nil) }
                for (offset, index) in region.base.enumerated() {
                    if offset == rows.count {
                        rows.append(VersionRow())
                    }
                    rows[offset].base = index
                }
                return Template(rows: rows, resultRepeats: nil)
            }
        }
    }

    /// The rows of one region, with the result's lines filled in from `resultStart`, its first line
    /// in the result. `choice` is the conflict's, and is ignored for any other region.
    static func rows(
        of template: Template,
        region: Int,
        resultStart: Int,
        choice: TextMerge.Choice?
    ) -> [MergeRow] {
        var rows = template.rows
        var result: [Int?] = Array(repeating: nil, count: rows.count)
        func repeating(_ column: MergeRow.Column, startingAt start: Int) -> Int {
            var next = start
            for (offset, row) in rows.enumerated()
                where (column == .yours ? row.yours : row.theirs) != nil {
                result[offset] = next
                next += 1
            }
            return next
        }
        /// `column`'s lines on the rows after the last one holding a result line.
        func following(_ column: MergeRow.Column, startingAt start: Int) {
            let count = rows.count(where: { (column == .yours ? $0.yours : $0.theirs) != nil })
            var offset = (result.lastIndex { $0 != nil } ?? -1) + 1
            for line in start..<start + count {
                if offset == rows.count {
                    rows.append(VersionRow())
                    result.append(nil)
                }
                result[offset] = line
                offset += 1
            }
        }
        switch template.resultRepeats ?? choice.map(Self.firstColumn) {
        case let column?:
            let next = repeating(column, startingAt: resultStart)
            if template.resultRepeats == nil, let choice, let second = Self.secondColumn(of: choice) {
                following(second, startingAt: next)
            }
        case nil:
            break
        }
        return zip(rows, result).map { row, result in
            MergeRow(
                region: region,
                yours: row.yours,
                result: result,
                theirs: row.theirs,
                base: row.base
            )
        }
    }

    private static func firstColumn(of choice: TextMerge.Choice) -> MergeRow.Column {
        switch choice {
        case .yours, .yoursThenTheirs: .yours
        case .theirs, .theirsThenYours: .theirs
        }
    }

    private static func secondColumn(of choice: TextMerge.Choice) -> MergeRow.Column? {
        switch choice {
        case .yours, .theirs: nil
        case .yoursThenTheirs: .theirs
        case .theirsThenYours: .yours
        }
    }
}
