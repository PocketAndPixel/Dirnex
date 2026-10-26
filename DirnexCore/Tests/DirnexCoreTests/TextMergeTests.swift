import Foundation
import Testing

@testable import DirnexCore

/// The merge window's model, case by case: its rows, the result each choice builds, and the steps
/// that undo them (PLAN.md §M34 Slice 2).
@Suite("TextMerge")
struct TextMergeTests {
    static func document(
        _ text: String,
        encoding: String.Encoding = .utf8,
        hasByteOrderMark: Bool = false
    ) -> ComparedDocument {
        ComparedDocument(
            lines: TextLines.split(text),
            encoding: encoding,
            hasByteOrderMark: hasByteOrderMark,
            isSavable: true
        )
    }

    static func merge(_ base: String, _ yours: String, _ theirs: String) -> TextMerge {
        TextMerge(base: document(base), yours: document(yours), theirs: document(theirs))
    }

    static func text(_ lines: [TextLine]) -> String {
        lines.map { String($0.content) + $0.terminator.text }.joined()
    }

    private static func row(
        _ region: Int,
        _ yours: Int?,
        _ result: Int?,
        _ theirs: Int?,
        _ base: Int?
    ) -> MergeRow {
        MergeRow(region: region, yours: yours, result: result, theirs: theirs, base: base)
    }

    @Test("a clean merge is resolved from the start, each region from the side that changed it")
    func cleanMerge() {
        let merge = Self.merge("a\nb\nc\n", "X\nb\nc\n", "a\nb\nY\n")
        #expect(merge.isResolved)
        #expect(merge.choices.isEmpty)
        #expect(Self.text(merge.result.lines) == "X\nb\nY\n")
        #expect(merge.rows == [
            Self.row(0, 0, 0, 0, 0),
            Self.row(1, 1, 1, 1, 1),
            Self.row(2, 2, 2, 2, 2)
        ])
    }

    @Test("a line one side inserted faces a gap in the others, and the result has it level")
    func insertionFacesGaps() {
        let merge = Self.merge("a\nc\n", "a\nb\nc\n", "a\nc\n")
        #expect(merge.rows == [
            Self.row(0, 0, 0, 0, 0),
            Self.row(1, 1, 1, nil, nil),
            Self.row(2, 2, 2, 1, 1)
        ])
        #expect(merge.paneText(for: .theirs).text == "a\n\nc\n")
        #expect(merge.paneText(for: .result).text == "a\nb\nc\n")
    }

    @Test("alike lines share a row, as in the compare window")
    func alikeLinesPair() {
        // Yours added a comment above the call it changed; the two calls sit on one row.
        let merge = Self.merge(
            "start\n    call(one: 1)\nend\n",
            "start\n    // why\n    call(one: 2)\nend\n",
            "start\n    call(one: 1)\nend\n"
        )
        #expect(merge.rows[1] == Self.row(1, 1, 1, nil, nil))
        #expect(merge.rows[2] == Self.row(1, 2, 2, 1, 1))
    }

    @Test("an open conflict has no result lines, and every choice puts its own there")
    func choices() throws {
        var merge = Self.merge("a\nb\nc\n", "a\nX\nc\n", "a\nY\nZ\nc\n")
        #expect(merge.choices == [nil])
        #expect(!merge.isResolved)
        #expect(Self.text(merge.result.lines) == "a\nc\n")
        #expect(merge.conflictRows == [1..<3])
        #expect(merge.rows == [
            Self.row(0, 0, 0, 0, 0),
            Self.row(1, 1, nil, 1, 1),
            Self.row(1, nil, nil, 2, nil),
            Self.row(2, 2, 1, 3, 2)
        ])
        let expected: [TextMerge.Choice: (text: String, rows: [MergeRow])] = [
            .yours: ("a\nX\nc\n", [Self.row(1, 1, 1, 1, 1), Self.row(1, nil, nil, 2, nil)]),
            .theirs: ("a\nY\nZ\nc\n", [Self.row(1, 1, 1, 1, 1), Self.row(1, nil, 2, 2, nil)]),
            .yoursThenTheirs: ("a\nX\nY\nZ\nc\n", [
                Self.row(1, 1, 1, 1, 1),
                Self.row(1, nil, 2, 2, nil),
                Self.row(1, nil, 3, nil, nil)
            ]),
            .theirsThenYours: ("a\nY\nZ\nX\nc\n", [
                Self.row(1, 1, 1, 1, 1),
                Self.row(1, nil, 2, 2, nil),
                Self.row(1, nil, 3, nil, nil)
            ])
        ]
        for choice in TextMerge.Choice.allCases {
            var chosen = merge
            chosen.apply(TextMerge.Step(conflict: 0, choice: choice))
            let (text, conflictRows) = try #require(expected[choice])
            #expect(Self.text(chosen.result.lines) == text, "\(choice)")
            #expect(Array(chosen.rows[chosen.conflictRows[0]]) == conflictRows, "\(choice)")
            #expect(chosen.rows.last?.result == chosen.result.lines.count - 1)
            #expect(chosen.isResolved)
        }
        merge.apply(TextMerge.Step(conflict: 0, choice: .yours))
        #expect(merge.choices == [.yours])
    }

    @Test(
        "every step returns the one that undoes it, and a step that changes nothing returns itself"
    )
    func undo() {
        var merge = Self.merge("a\nb\nc\nd\ne\n", "a\nX\nc\nV\ne\n", "a\nY\nc\nW\ne\n")
        #expect(merge.choices.count == 2)
        let opened = merge.result.lines
        let first = merge.apply(TextMerge.Step(conflict: 1, choice: .theirs))
        #expect(first == TextMerge.Step(conflict: 1, choice: nil))
        let second = merge.apply(TextMerge.Step(conflict: 0, choice: .yoursThenTheirs))
        let third = merge.apply(TextMerge.Step(conflict: 1, choice: .yours))
        #expect(third == TextMerge.Step(conflict: 1, choice: .theirs))
        #expect(Self.text(merge.result.lines) == "a\nX\nY\nc\nV\ne\n")
        let same = TextMerge.Step(conflict: 1, choice: .yours)
        #expect(merge.apply(same) == same)
        merge.apply(third)
        merge.apply(second)
        #expect(Self.text(merge.result.lines) == "a\nc\nW\ne\n")
        merge.apply(first)
        #expect(merge.result.lines == opened)
        #expect(merge.choices == [nil, nil])
    }

    @Test("taking both gives the first side's last line a break, the result's own, when it has none")
    func bothSidesAtTheEnd() {
        for (ending, text) in [("\n", "a\nX\nY"), ("\r\n", "a\r\nX\r\nY")] {
            var merge = Self.merge("a\(ending)b", "a\(ending)X", "a\(ending)Y")
            merge.apply(TextMerge.Step(conflict: 0, choice: .yoursThenTheirs))
            #expect(Self.text(merge.result.lines) == text)
            merge.apply(TextMerge.Step(conflict: 0, choice: .yours))
            #expect(Self.text(merge.result.lines) == "a\(ending)X")
        }
        // Nothing follows the first side's lines when the second side has none, so no break.
        var merge = Self.merge("a\nb", "a\nX", "a\n")
        merge.apply(TextMerge.Step(conflict: 0, choice: .yoursThenTheirs))
        #expect(Self.text(merge.result.lines) == "a\nX")
    }

    @Test(
        "the result is yours' document: its encoding, its byte-order mark, and edited only by change"
    )
    func resultIsYours() {
        let base = Self.document("a\nb\nc\n")
        let yours = Self.document("a\nb\nX\n", encoding: .utf16LittleEndian, hasByteOrderMark: true)
        let unchanged = TextMerge(base: base, yours: yours, theirs: base)
        #expect(unchanged.result.encoding == .utf16LittleEndian)
        #expect(unchanged.result.hasByteOrderMark)
        #expect(!unchanged.result.isEdited)
        let merged = TextMerge(base: base, yours: yours, theirs: Self.document("A\nb\nc\n"))
        #expect(merged.result.isEdited)
        #expect(Self.text(merged.result.lines) == "A\nb\nX\n")
    }

    @Test("conflicts are found from any row, open ones only when asked")
    func movingBetweenConflicts() {
        var merge = Self.merge(
            "a\nb\nc\nd\ne\nf\ng\n",
            "a\nB1\nc\nD1\ne\nF1\ng\n",
            "a\nB2\nc\nD2\ne\nF2\ng\n"
        )
        #expect(merge.conflictRows == [1..<2, 3..<4, 5..<6])
        #expect(merge.conflict(after: -1) == 0)
        #expect(merge.conflict(after: 1) == 1)
        #expect(merge.conflict(after: 5) == nil)
        #expect(merge.conflict(before: merge.rows.count) == 2)
        #expect(merge.conflict(before: 1) == nil)
        #expect(merge.conflict(containing: 3) == 1)
        #expect(merge.conflict(containing: 2) == nil)
        merge.apply(TextMerge.Step(conflict: 1, choice: .theirs))
        #expect(merge.conflict(after: 1, onlyOpen: true) == 2)
        #expect(merge.conflict(before: 5, onlyOpen: true) == 0)
        #expect(merge.openConflictCount == 2)
    }

    @Test("every column's pane has a line per row")
    func panes() {
        let merge = Self.merge("a\nb\nc\n", "a\nX\nc\n", "a\nY\nZ\nc\n")
        for column in MergeRow.Column.allCases {
            let pane = merge.paneText(for: column)
            #expect(pane.rowStarts.count == merge.rows.count, "\(column)")
            #expect(pane.side == nil)
        }
        #expect(merge.paneText(for: .base).text == "a\nb\n\nc\n")
        #expect(merge.paneText(for: .result).text == "a\n\n\nc\n")
    }
}
