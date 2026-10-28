import AppKit
import DirnexCore

/// Everything one state of a merge shows (PLAN.md §M34 Slice 3): each column's text, the color of
/// each of its rows and its syntax colors, and the marks the bands and the overview strip draw.
/// Built off the main thread from a `TextMerge`, as the compare window's `Prepared` is built from a
/// comparison; the main thread only sets the text.
struct MergePrepared: Sendable {
    /// One column as its pane shows it.
    struct Pane: Sendable {
        let text: ComparisonPaneText
        let fills: [AlignedRowFill]
        let tokens: [SyntaxToken]
        /// How many lines the column's own text has, which sizes its gutter.
        let lineCount: Int
    }

    let panes: [MergeRow.Column: Pane]
    let rowCount: Int
    /// The rows of each region that is not unchanged, in order, and what each one is: a change that
    /// merged on its own, an open conflict or a chosen one.
    let markRows: [Range<Int>]
    let markKinds: [CompareChangeKind]
    /// Each conflict's rows, and its place among the marks.
    let conflictRows: [Range<Int>]
    let conflictMarks: [Int]
    /// How many conflicts have no choice yet.
    let openConflictCount: Int

    var conflictCount: Int { conflictRows.count }

    /// Prepare `merge` for the screen, coloring syntax by `language` in a pane of at most
    /// `coloringLimit` UTF-16 units. Blocking; call it off the main thread.
    nonisolated static func prepare(
        _ merge: TextMerge,
        language: SyntaxLanguage?,
        coloringLimit: Int
    ) -> MergePrepared {
        let regions = merge.merge.regions
        // Whether each region is a conflict with a choice.
        var chosen = Array(repeating: false, count: regions.count)
        var conflict = 0
        for (index, region) in regions.enumerated() where region.kind == .conflict {
            chosen[index] = merge.choices[conflict] != nil
            conflict += 1
        }
        var panes: [MergeRow.Column: Pane] = [:]
        for column in MergeRow.Column.allCases {
            let text = merge.paneText(for: column)
            let tokens: [SyntaxToken] = if let language, text.text.utf16.count <= coloringLimit {
                SyntaxHighlighter.tokens(in: text.text, language: language)
            } else {
                []
            }
            panes[column] = Pane(
                text: text,
                fills: merge.rows.map { row in
                    fill(
                        column,
                        of: row,
                        kind: regions[row.region].kind,
                        isChosen: chosen[row.region]
                    )
                },
                tokens: tokens,
                lineCount: lineCount(of: column, in: merge)
            )
        }
        var markRows: [Range<Int>] = []
        var markKinds: [CompareChangeKind] = []
        var conflictMarks: [Int] = []
        var start = 0
        while start < merge.rows.count {
            let region = merge.rows[start].region
            var end = start + 1
            while end < merge.rows.count, merge.rows[end].region == region {
                end += 1
            }
            switch regions[region].kind {
            case .unchanged:
                break
            case .conflict:
                conflictMarks.append(markRows.count)
                markRows.append(start..<end)
                markKinds.append(chosen[region] ? .resolved : .conflict)
            case .yours, .theirs, .same:
                markRows.append(start..<end)
                markKinds.append(.change)
            }
            start = end
        }
        return MergePrepared(
            panes: panes,
            rowCount: merge.rows.count,
            markRows: markRows,
            markKinds: markKinds,
            conflictRows: merge.conflictRows,
            conflictMarks: conflictMarks,
            openConflictCount: merge.openConflictCount
        )
    }

    /// How `column` paints `row`, of a region of `kind`, chosen for when it is a conflict.
    ///
    /// A change that merges on its own is marked in each column that shows it: the side that made
    /// it, the result and the base it replaced, while the side that did not change says what the base
    /// says and is left plain. A conflict is marked in every column until it has a choice, the
    /// result's empty rows included, since that is where its lines will go.
    nonisolated static func fill(
        _ column: MergeRow.Column,
        of row: MergeRow,
        kind: ThreeWayMerge.Kind,
        isChosen: Bool
    ) -> AlignedRowFill {
        let hasLine = row.line(in: column) != nil
        switch kind {
        case .unchanged:
            return hasLine ? .same : .gap
        case .conflict:
            if column == .result, !isChosen { return .conflict }
            guard hasLine else { return .gap }
            return isChosen ? .resolved : .conflict
        case .yours, .theirs, .same:
            guard hasLine else { return .gap }
            let unchangedSide: MergeRow.Column? = switch kind {
            case .yours: .theirs
            case .theirs: .yours
            default: nil
            }
            return column == unchangedSide ? .same : .changed
        }
    }

    private nonisolated static func lineCount(of column: MergeRow.Column, in merge: TextMerge) -> Int {
        switch column {
        case .yours: merge.yours.lines.count
        case .result: merge.result.lines.count
        case .theirs: merge.theirs.lines.count
        case .base: merge.base.lines.count
        }
    }
}
