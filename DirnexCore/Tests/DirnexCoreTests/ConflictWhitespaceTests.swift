import Foundation
import Testing

@testable import DirnexCore

/// What whitespace explains in a conflict, and the take that keeps both edits (PLAN.md §M37 Slice 5),
/// case by case. The first four are the cases git's ignore options were probed on, each of which git
/// settles by dropping the whitespace edit.
@Suite("ConflictWhitespace")
struct ConflictWhitespaceTests {
    private static func merge(_ base: String, _ yours: String, _ theirs: String) -> TextMerge {
        TextMergeTests.merge(base, yours, theirs)
    }

    private static func text(_ lines: [TextLine]?) -> String? {
        lines.map(TextMergeTests.text)
    }

    /// The result after conflict 0 takes `.editWithWhitespace`, which it must offer.
    private static func taken(_ merge: TextMerge) throws -> String {
        try #require(merge.offers(.editWithWhitespace, forConflict: 0))
        var merge = merge
        merge.apply(TextMerge.Step(conflict: 0, choice: .editWithWhitespace))
        return TextMergeTests.text(merge.result.lines)
    }

    // MARK: - git's four cases

    @Test("yours re-indents and theirs edits a line: theirs' edit, yours' indentation")
    func reindentAgainstAnEdit() throws {
        let merge = Self.merge(
            "f {\n  a\n  B\n  c\n}\n",
            "f {\n    a\n    B\n    c\n}\n",
            "f {\n  a\n  B!\n  c\n}\n"
        )
        #expect(merge.choices.count == 1)
        #expect(merge.whitespace.first??.kind == .yoursOnlyWhitespace)
        #expect(merge.whitespace.first??.editSide == .theirs)
        #expect(Self.text(merge.whitespace.first??.combined) == "    a\n    B!\n    c\n")
        #expect(merge.offers(.editWithWhitespace, forConflict: 0))
        #expect(try Self.taken(merge) == "f {\n    a\n    B!\n    c\n}\n")
    }

    @Test("the mirror image: yours' edit, theirs' indentation")
    func editAgainstAReindent() throws {
        let merge = Self.merge(
            "f {\n  a\n  B\n  c\n}\n",
            "f {\n  a\n  B!\n  c\n}\n",
            "f {\n\ta\n\tB\n\tc\n}\n"
        )
        #expect(merge.whitespace.first??.kind == .theirsOnlyWhitespace)
        #expect(merge.whitespace.first??.editSide == .yours)
        #expect(try Self.taken(merge) == "f {\n\ta\n\tB!\n\tc\n}\n")
    }

    @Test("both re-indent differently: labelled, and no take beyond the sides")
    func bothReindent() {
        let merge = Self.merge(
            "f {\n  a\n  B\n  c\n}\n",
            "f {\n    a\n    B\n    c\n}\n",
            "f {\n\ta\n\tB\n\tc\n}\n"
        )
        #expect(
            merge.whitespace == [
                ConflictWhitespace(kind: .sidesDifferOnlyInWhitespace, combined: nil)
            ]
        )
        #expect(merge.whitespace.first??.editSide == nil)
        #expect(!merge.offers(.editWithWhitespace, forConflict: 0))
        #expect(merge.offers(.yours, forConflict: 0))
    }

    @Test("yours strips trailing spaces: theirs' edit, without them")
    func trailingSpaces() throws {
        let merge = Self.merge(
            "f {\n  a  \n  B  \n  c\n}\n",
            "f {\n  a\n  B\n  c\n}\n",
            "f {\n  a  \n  B!  \n  c\n}\n"
        )
        #expect(merge.whitespace.first??.kind == .yoursOnlyWhitespace)
        #expect(try Self.taken(merge) == "f {\n  a\n  B!\n  c\n}\n")
    }

    @Test("yours turns every line ending into CRLF: theirs' edit in CRLF, its new line included")
    func lineEndings() throws {
        let merge = Self.merge(
            "alpha\nbravo\ncharlie\ndelta\n",
            "alpha\r\nbravo\r\ncharlie\r\ndelta\r\n",
            "alpha\nBRAVO 2\nnew\ncharlie\ndelta\n"
        )
        #expect(merge.whitespace.first??.kind == .yoursOnlyWhitespace)
        #expect(try Self.taken(merge) == "alpha\r\nBRAVO 2\r\nnew\r\ncharlie\r\ndelta\r\n")
    }

    // MARK: - What a conflict is read with

    @Test("the lines the trimming moved out are read with the conflict")
    func trimmedLinesCount() throws {
        // Both sides re-indented `a` alike, so it moves out of the conflict; yours' change is still
        // only whitespace, over the whole stretch the base had.
        let merge = Self.merge(
            "f {\n  a\n  B\n  c\n}\n",
            "f {\n    a\n    B\n    c\n}\n",
            "f {\n    a\n  B!\n  c\n}\n"
        )
        #expect(merge.merge.regions.map(\.kind) == [.unchanged, .same, .conflict, .unchanged])
        #expect(merge.whitespace.first??.kind == .yoursOnlyWhitespace)
        #expect(Self.text(merge.whitespace.first??.combined) == "    B!\n    c\n")
        #expect(try Self.taken(merge) == "f {\n    a\n    B!\n    c\n}\n")
    }

    @Test("a real edit on each side is not whitespace, nor is a blank line")
    func notWhitespace() {
        #expect(Self.merge("a\nb\nc\n", "a\nX\nc\n", "a\nY\nc\n").whitespace == [nil])
        // A blank line yours added is a line, not whitespace.
        let blank = Self.merge("a\nb\nc\n", "a\n\nb\nc\n", "a\nB\nc\n")
        #expect(blank.whitespace == [nil])
        #expect(!blank.offers(.editWithWhitespace, forConflict: 0))
    }

    @Test("one edit on both sides, spaced differently, is labelled")
    func sameEditSpacedDifferently() {
        let merge = Self.merge("x\n", "  y = 1\n", "y  =  1\n")
        #expect(merge.whitespace.first??.kind == .sidesDifferOnlyInWhitespace)
    }

    // MARK: - When the whitespace cannot be carried

    @Test("a line whose indentation both sides changed differently is labelled with no take")
    func indentationBothChanged() {
        let merge = Self.merge("  x = 1\n  y\n", "    x = 1\n    y\n", "x = 2\n  y\n")
        #expect(merge.whitespace.first??.kind == .yoursOnlyWhitespace)
        #expect(merge.whitespace.first??.combined == nil)
        #expect(!merge.offers(.editWithWhitespace, forConflict: 0))
        // A line replaced by another at the margin, set beside the one it replaced: the same.
        let replaced = Self.merge("  old line\n", "    old line\n", "completely different\n")
        #expect(replaced.whitespace.first??.combined == nil)
    }

    @Test("spacing inside a line the other side edited cannot be carried")
    func interiorSpacing() {
        let merge = Self.merge("let a  =  b\n", "let a = b\n", "let a  =  c\n")
        #expect(merge.whitespace.first??.kind == .yoursOnlyWhitespace)
        #expect(merge.whitespace.first??.combined == nil)
    }

    @Test("no take where carrying changes nothing: the edit removed every line respaced")
    func nothingToCarry() {
        // Taking theirs already is theirs with yours' whitespace: nothing of yours' is left to carry.
        let merge = Self.merge("keep\n  gone\n", "keep\n    gone\n", "keep\n")
        #expect(merge.whitespace.first??.kind == .yoursOnlyWhitespace)
        #expect(merge.whitespace.first??.combined == nil)
        #expect(!merge.offers(.editWithWhitespace, forConflict: 0))
    }

    // MARK: - The take in the merge

    @Test("the take's lines sit level with the edit side's, and undo opens the conflict again")
    func takeRowsAndUndo() {
        var merge = Self.merge(
            "f {\n  a\n  B\n  c\n}\n",
            "f {\n    a\n    B\n    c\n}\n",
            "f {\n  a\n  new\n  B!\n  c\n}\n"
        )
        let opened = merge
        let undo = merge.apply(TextMerge.Step(conflict: 0, choice: .editWithWhitespace))
        #expect(undo == TextMerge.Step(conflict: 0, choice: nil))
        #expect(merge.isResolved)
        #expect(TextMergeTests.text(merge.result.lines) == "f {\n    a\n    new\n    B!\n    c\n}\n")
        for row in merge.rows[merge.conflictRows[0]] {
            // One result line on each row of theirs', and none on a row without.
            #expect((row.result == nil) == (row.theirs == nil))
        }
        merge.apply(undo)
        #expect(merge.rows == opened.rows)
        #expect(merge.result.lines == opened.result.lines)
    }
}

/// The carrying rule itself, line by line (`WhitespaceCarry`).
@Suite("WhitespaceCarry")
struct WhitespaceCarryTests {
    private static func carry(spacing: String, base: String, edit: String) -> String? {
        WhitespaceCarry.carry(
            spacing: TextLines.split(spacing),
            base: TextLines.split(base),
            onto: TextLines.split(edit)
        ).map(TextMergeTests.text)
    }

    @Test(
        "spacing equal to the base gives the edit back, and an edit equal to the base gives the spacing"
    )
    func identities() {
        let base = "  a\n\tb  \nc\r\n"
        let other = "  a!\n\tb\nnew\nc\r\n"
        #expect(Self.carry(spacing: base, base: base, edit: other) == other)
        let spacing = "    a\n    b\nc\n"
        #expect(Self.carry(spacing: spacing, base: base, edit: base) == spacing)
    }

    @Test("a line nested deeper keeps its extra depth, and a shallower one cannot be carried")
    func indentationPrefix() {
        #expect(Self.carry(spacing: "    x\n", base: "  x\n", edit: "      x!\n") == "        x!\n")
        #expect(Self.carry(spacing: "  x\n", base: "    x\n", edit: "      x!\n") == "    x!\n")
        #expect(Self.carry(spacing: "        x\n", base: "    x\n", edit: "  x!\n") == nil)
    }

    @Test("an added line follows the longest matching indentation, the nearest on a tie")
    func addedLines() {
        // Tabs became spaces; the added line two deep takes the two-deep mapping.
        #expect(Self.carry(
            spacing: "    a\n        b\n    c\n",
            base: "\ta\n\t\tb\n\tc\n",
            edit: "\ta\n\t\tb\n\t\tadded\n\tc\n"
        ) == "    a\n        b\n        added\n    c\n")
        // A blank line keeps its indentation, and one shallower than every paired line stays.
        #expect(Self.carry(
            spacing: "    a\n    b\n",
            base: "  a\n  b\n",
            edit: "  a\n\nout\n  b\n"
        ) == "    a\n\nout\n    b\n")
        // Two neighbours with different mappings: the one above wins a tie.
        #expect(Self.carry(
            spacing: "    a\n  b\n",
            base: "  a\n  b\n",
            edit: "  a\n  mid\n  b\n"
        ) == "    a\n    mid\n  b\n")
    }

    @Test("an added last line takes the final line break the spacing gave the file")
    func finalLineBreak() {
        #expect(
            Self.carry(spacing: "x = 1\n", base: "x = 1", edit: "x = 2\ny = 3") == "x = 2\ny = 3\n"
        )
    }

    @Test("bytes, not characters: a combining mark after an indentation stays where it was")
    func bytesNotCharacters() {
        // A space followed by U+0301 is one `Character`, which a `String` split would not cut.
        let base = " \u{301}é\n"
        let carried = Self.carry(spacing: "   \u{301}é\n", base: base, edit: " \u{301}é!\n")
        #expect(carried.map { Array($0.utf8) } == Array("   \u{301}é!\n".utf8))
    }
}
