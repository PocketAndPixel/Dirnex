import Foundation
import Testing

@testable import DirnexCore

@Suite("Aligned rows")
struct AlignedRowsTests {
    private func comparison(
        _ left: String,
        _ right: String,
        options: LineDiffOptions = LineDiffOptions()
    ) -> TextComparison {
        TextComparison(ComparedText(text: left), ComparedText(text: right), options: options)
    }

    /// Each row as `kind left right`, with `-` for a gap, so one comparison checks the layout.
    private func shape(_ comparison: TextComparison) -> [String] {
        comparison.rows.map { row in
            "\(row.kind) \(row.left.map(String.init) ?? "-") \(row.right.map(String.init) ?? "-")"
        }
    }

    @Test("identical texts are all same rows, line for line")
    func identical() {
        let result = comparison("a\nb\n", "a\nb\n")
        #expect(shape(result) == ["same 0 0", "same 1 1"])
        #expect(result.changeRows.isEmpty)
    }

    @Test("an insertion faces a gap, and the lines after it stay level")
    func insertionFacesAGap() {
        let result = comparison("a\nc\n", "a\nb\nc\n")
        #expect(shape(result) == ["same 0 0", "inserted - 1", "same 1 2"])
        #expect(result.changeRows == [1..<2])
    }

    @Test("a changed line that is alike its old self is one row, with the words that differ marked")
    func alikeLinesShareARow() throws {
        let result = comparison("let total = count + 1\n", "let total = sum + 1\n")
        #expect(shape(result) == ["changed 0 0"])
        let inline = try #require(result.rows[0].inline)
        #expect(inline.left == [12..<17])
        #expect(inline.right == [12..<15])
    }

    @Test("a comment added above a changed call faces a gap, and the two calls share a row")
    func pairingFollowsLikeness() {
        let result = comparison("x\n    foo(a)\ny\n", "x\n    // why\n    foo(b)\ny\n")
        #expect(shape(result) == ["same 0 0", "inserted - 1", "changed 1 2", "same 2 3"])
        #expect(result.rows[2].inline != nil)
    }

    @Test("of two lines, the one alike the other side's line is the one paired with it")
    func pairingPicksTheAlikeLine() {
        let result = comparison("foo(a)\nbar(x)\n", "bar(y)\n")
        #expect(shape(result) == ["removed 0 -", "changed 1 0"])
    }

    @Test("lines with nothing in common still share rows from the top, with nothing marked inside")
    func unalikeLinesGoSideBySide() {
        let result = comparison("alpha\nbeta\n", "}\n")
        #expect(shape(result) == ["changed 0 0", "removed 1 -"])
        #expect(result.rows[0].inline == nil)
    }

    @Test("a block too large to pair by likeness pairs line for line from the top")
    func largeBlocksPairFromTheTop() {
        let left = (0..<120).map { "item \($0)\n" }.joined()
        let right = (0..<120).map { "item \($0) changed\n" }.joined()
        let result = comparison(left, right)
        #expect(result.rows.count == 120)
        let allPaired = result.rows.allSatisfy { $0.kind == .changed && $0.left == $0.right && $0.inline != nil }
        #expect(allPaired)
    }

    @Test("a line that only changed its ending is a changed row with nothing marked inside")
    func lineEndingOnly() throws {
        let result = comparison("a\r\nb\n", "a\nb\n")
        #expect(shape(result) == ["changed 0 0", "same 1 1"])
        #expect(result.rows[0].lineEndingsDiffer)
        let inline = try #require(result.rows[0].inline)
        #expect(inline.left.isEmpty && inline.right.isEmpty)
    }

    @Test("with line endings ignored, the row is the same and still says its ending differs")
    func lineEndingIgnored() {
        let result = comparison(
            "a\r\nb\n",
            "a\nb\n",
            options: LineDiffOptions(ignoresLineEndings: true)
        )
        #expect(shape(result) == ["same 0 0", "same 1 1"])
        #expect(result.rows[0].lineEndingsDiffer)
        #expect(!result.rows[1].lineEndingsDiffer)
    }

    @Test("moving between changes goes by each change's first row, and stops at the ends")
    func navigation() {
        let result = comparison("a\nb\nc\nd\ne\n", "a\nB\nc\nD\ne\n")
        #expect(result.changeRows == [1..<2, 3..<4])
        #expect(result.change(after: -1) == 1..<2)
        #expect(result.change(after: 1) == 3..<4)
        #expect(result.change(after: 3) == nil)
        #expect(result.change(before: 3) == 1..<2)
        #expect(result.change(before: 1) == nil)
        #expect(result.change(before: 99) == 3..<4)
        #expect(result.changeIndex(containing: 3) == 1)
        #expect(result.changeIndex(containing: 2) == nil)
    }

    @Test("every line appears in exactly one row, in order, on 300 random pairs")
    func everyLineOnce() {
        var rng = SeededGenerator(seed: 0x0031_0006)
        let vocabulary = ["", "}", "foo(a)", "foo(b)", "bar", "    baz()", "// note"]
        func text() -> String {
            (0..<Int.random(in: 0...25, using: &rng))
                .map { _ in vocabulary[Int.random(in: 0..<vocabulary.count, using: &rng)] + "\n" }
                .joined()
        }
        for _ in 0..<300 {
            let result = comparison(text(), text())
            let leftOrder = result.rows.compactMap(\.left)
            let rightOrder = result.rows.compactMap(\.right)
            #expect(leftOrder == Array(result.leftLines.indices))
            #expect(rightOrder == Array(result.rightLines.indices))
            let changedRows = result.changeRows.flatMap { Array($0) }
            let notSame = result.rows.indices.filter { result.rows[$0].kind != .same }
            #expect(changedRows == notSame)
        }
    }

    @Test("likeness: shared pairs of characters over all pairs, with indentation left out")
    func likeness() {
        func alike(_ left: Substring, _ right: Substring, ignoresCase: Bool = false) -> Double {
            LineFingerprint(left, ignoresCase: ignoresCase)
                .similarity(to: LineFingerprint(right, ignoresCase: ignoresCase))
        }
        #expect(alike("foo(a)", "foo(b)") == 0.6)
        #expect(alike("    foo(a)", "foo(a)") == 1)
        #expect(alike("// comment", "foo(b)") < LineFingerprint.pairingThreshold)
        #expect(alike("Hello", "hello") < 1)
        #expect(alike("Hello", "hello", ignoresCase: true) == 1)
        #expect(alike("}", "{") == 0)
    }
}
