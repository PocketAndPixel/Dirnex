import Foundation
import Testing

@testable import DirnexCore

@Suite("ComparisonPaneText")
struct ComparisonPaneTextTests {
    private func panes(_ left: String, _ right: String) -> (ComparisonPaneText, ComparisonPaneText) {
        let comparison = TextComparison(ComparedText(text: left), ComparedText(text: right))
        return (
            ComparisonPaneText(comparison, side: .left),
            ComparisonPaneText(comparison, side: .right)
        )
    }

    @Test(
        "both panes have a line per row, a gap is an empty line, and every row ends in a line break"
    )
    func linePerRow() {
        let (left, right) = panes("a\nc\n", "a\nb\nc\n")
        #expect(left.text == "a\n\nc\n")
        #expect(right.text == "a\nb\nc\n")
        #expect(left.rowStarts == [0, 2, 3])
        #expect(right.rowStarts == [0, 2, 4])
        #expect(left.lineIndex(ofRow: 1) == nil)
        #expect(right.lineIndex(ofRow: 1) == 1)
        #expect(left.lineIndex(ofRow: 2) == 1)
    }

    @Test("rows are found by UTF-16 offset, a line break belonging to the row it ends")
    func rowLookup() {
        let (_, right) = panes("x\n", "😀b\ncd\nef\n")
        #expect(right.rowStarts == [0, 4, 7])
        #expect(right.row(containingUTF16Offset: 0) == 0)
        #expect(right.row(containingUTF16Offset: 3) == 0)
        #expect(right.row(containingUTF16Offset: 4) == 1)
        #expect(right.row(containingUTF16Offset: 9) == 2)
        #expect(right.range(ofRow: 0) == 0..<3)
        #expect(right.range(ofRow: 2) == 7..<9)
    }

    @Test("characters a text view breaks a line at are shown as symbols of the same UTF-16 width")
    func standIns() {
        let (left, _) = panes("a\u{2028}b\u{85}c\u{0B}d\u{0C}e\u{2029}f\n", "")
        #expect(left.text == "a\u{2424}b\u{2424}c\u{240B}d\u{240C}e\u{2424}f\n")
        #expect(left.text.utf16.count == 12)
    }

    @Test("a line past the limit is cut and marked, and copying it whole gives the whole line")
    func longLines() {
        let long = String(repeating: "x", count: ComparisonPaneText.maximumShownLength + 50)
        let (left, _) = panes(long + "\n", "")
        #expect(left.text.utf16.count == ComparisonPaneText.maximumShownLength + 2)
        #expect(left.text.hasSuffix("x…\n"))
        #expect(left.originalText(for: 0..<left.text.utf16.count - 1) == long)
        #expect(left.originalText(for: 0..<left.text.utf16.count) == long + "\n")
    }

    @Test("copying gives the file's own text: gaps give nothing, and lines keep their own endings")
    func copying() {
        let (left, right) = panes("one\r\ntwo\nthree", "one\r\n2\ntwo\nthree")
        // Left: "one", gap, "two", "three"; right: "one", "2", "two", "three".
        #expect(left.text == "one\n\ntwo\nthree\n")
        #expect(left.originalText(for: 0..<left.text.utf16.count) == "one\r\ntwo\nthree")
        #expect(right.originalText(for: 0..<right.text.utf16.count) == "one\r\n2\ntwo\nthree")
        // Part of one line, and a selection that runs past a line's end takes its line break.
        #expect(left.originalText(for: 1..<3) == "ne")
        #expect(left.originalText(for: 1..<4) == "ne\r\n")
        // A selection holding only a gap gives nothing at all.
        #expect(left.originalText(for: 4..<5).isEmpty)
        #expect(left.originalText(for: 0..<0).isEmpty)
    }

    @Test("width is counted in columns: tabs to the next stop of four, wide characters as two")
    func columns() {
        #expect(ComparisonPaneText.columns(of: "abc") == 3)
        #expect(ComparisonPaneText.columns(of: "\tx") == 5)
        #expect(ComparisonPaneText.columns(of: "ab\tx") == 5)
        #expect(ComparisonPaneText.columns(of: "漢字") == 4)
        #expect(ComparisonPaneText.columns(of: "😀a") == 3)
        #expect(ComparisonPaneText.columns(of: "e\u{301}") == 1)
        let (left, right) = panes("ab\n漢字漢字\n", "\t\tz\n")
        #expect(left.widestColumns == 8)
        #expect(right.widestColumns == 9)
    }

    @Test("an empty comparison has no rows and copies nothing")
    func empty() {
        let (left, _) = panes("", "")
        #expect(left.text.isEmpty)
        #expect(left.rowStarts.isEmpty)
        #expect(left.originalText(for: 0..<1).isEmpty)
    }
}
