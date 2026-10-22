import Foundation
import Testing

@testable import DirnexCore

@Suite("LineDiff")
struct LineDiffTests {
    private func change(_ left: Range<Int>, _ right: Range<Int>) -> LineDiff.Change {
        LineDiff.Change(left: left, right: right)
    }

    @Test("identical texts have no changes")
    func identical() {
        let diff = LineDiff.compare("a\nb\n", "a\nb\n")
        #expect(diff.isIdentical)
        #expect(diff.leftLineCount == 2)
        #expect(diff.rightLineCount == 2)
        #expect(LineDiff.compare("", "").isIdentical)
    }

    @Test("a line replaced in the middle is one block on each side")
    func replacement() {
        let diff = LineDiff.compare("a\nb\nc\n", "a\nX\nc\n")
        #expect(diff.changes == [change(1..<2, 1..<2)])
        #expect(diff.removedLineCount == 1)
        #expect(diff.insertedLineCount == 1)
    }

    @Test("an insertion has an empty left range, and a removal an empty right range")
    func insertionAndRemoval() {
        #expect(LineDiff.compare("a\nc\n", "a\nb\nc\n").changes == [change(1..<1, 1..<2)])
        #expect(LineDiff.compare("a\nb\nc\n", "a\nc\n").changes == [change(1..<2, 1..<1)])
    }

    @Test("against an empty text, every line is inserted or removed")
    func againstEmpty() {
        #expect(LineDiff.compare("", "a\nb\n").changes == [change(0..<0, 0..<2)])
        #expect(LineDiff.compare("a\nb\n", "").changes == [change(0..<2, 0..<0)])
    }

    @Test("separate edits are separate blocks, in order")
    func separateBlocks() {
        let diff = LineDiff.compare("a\nb\nc\nd\ne\n", "a\nB\nc\nD\ne\n")
        #expect(diff.changes == [change(1..<2, 1..<2), change(3..<4, 3..<4)])
    }

    @Test("a missing final newline changes the last line, as it does in git")
    func missingFinalNewline() {
        #expect(LineDiff.compare("a\nb", "a\nb\n").changes == [change(1..<2, 1..<2)])
        let ignoring = LineDiffOptions(ignoresLineEndings: true)
        #expect(LineDiff.compare("a\nb", "a\nb\n", options: ignoring).isIdentical)
    }

    @Test("CRLF against LF changes every line, unless line endings are ignored")
    func lineEndings() {
        #expect(LineDiff.compare("a\r\nb\r\n", "a\nb\n").changes == [change(0..<2, 0..<2)])
        let ignoring = LineDiffOptions(ignoresLineEndings: true)
        #expect(LineDiff.compare("a\r\nb\r\n", "a\nb\n", options: ignoring).isIdentical)
        #expect(LineDiff.compare("a\rb\r", "a\nb\n", options: ignoring).isIdentical)
    }

    /// One line against `a b`, and the whitespace options under which git calls the two the same.
    /// Every row was probed against git 2.54 on 2026-10-22 (PLAN.md §M31).
    struct WhitespaceCase: Sendable, CustomTestStringConvertible {
        let line: String
        let sameUnder: Set<LineDiffOptions.Whitespace>
        var testDescription: String { line.debugDescription }
    }

    static let whitespaceCases: [WhitespaceCase] = [
        WhitespaceCase(line: "a  b ", sameUnder: [.ignoreChanges, .ignoreAll]),
        WhitespaceCase(line: "ab", sameUnder: [.ignoreAll]),
        WhitespaceCase(line: " a b", sameUnder: [.ignoreAll]),
        WhitespaceCase(line: "a\tb", sameUnder: [.ignoreChanges, .ignoreAll]),
        WhitespaceCase(line: "a b \t", sameUnder: [.ignoreTrailing, .ignoreChanges, .ignoreAll]),
        // git's whitespace is a space or a tab, so these are content to every option.
        WhitespaceCase(line: "a\u{0B}b", sameUnder: []),
        WhitespaceCase(line: "a\u{0C}b", sameUnder: []),
        WhitespaceCase(line: "a\u{A0}b", sameUnder: [])
    ]

    @Test("each whitespace option matches what its git flag matches", arguments: whitespaceCases)
    func whitespace(_ testCase: WhitespaceCase) {
        let all: [LineDiffOptions.Whitespace] = [
            .compare,
            .ignoreTrailing,
            .ignoreChanges,
            .ignoreAll
        ]
        for whitespace in all {
            let diff = LineDiff.compare(
                "a b\n",
                testCase.line + "\n",
                options: LineDiffOptions(whitespace: whitespace)
            )
            #expect(
                diff.isIdentical == testCase.sameUnder.contains(whitespace),
                "\(testCase.line.debugDescription) under \(whitespace)"
            )
        }
    }

    @Test("every whitespace option also overlooks the line terminator, as git's do")
    func whitespaceOverlooksTerminators() {
        for whitespace in [LineDiffOptions.Whitespace.ignoreTrailing, .ignoreChanges, .ignoreAll] {
            let options = LineDiffOptions(whitespace: whitespace)
            #expect(LineDiff.compare("a\r\nb", "a\nb\n", options: options).isIdentical)
        }
    }

    @Test("ignoring case matches letters in any case, and nothing more")
    func ignoringCase() {
        let options = LineDiffOptions(ignoresCase: true)
        #expect(LineDiff.compare("Hello World\nПривет\n", "hello WORLD\nпривет\n", options: options)
            .isIdentical)
        #expect(!LineDiff.compare("Hello\n", "Hallo\n", options: options).isIdentical)
        #expect(!LineDiff.compare("Hello\n", "hello\n").isIdentical)
    }

    @Test("lines compare as bytes: é precomposed and decomposed differ, as they do to git")
    func canonicalEquivalentsDiffer() {
        let precomposed = "caf\u{E9}\n"
        let decomposed = "cafe\u{301}\n"
        // The trap is real: Swift calls the two strings equal, and so would a key built on them.
        #expect(precomposed == decomposed)
        #expect(LineDiff.compare(precomposed, decomposed).changes == [change(0..<1, 0..<1)])
        #expect(!LineDiff.compare(
            precomposed,
            decomposed,
            options: LineDiffOptions(whitespace: .ignoreAll, ignoresCase: true)
        ).isIdentical)
    }

    @Test("a line that appears on one side only is reported changed, wherever it is")
    func oneSidedLines() {
        let diff = LineDiff.compare("a\nonly-left\nb\nc\n", "a\nb\nonly-right\nc\n")
        #expect(diff.changes == [change(1..<2, 1..<1), change(3..<3, 2..<3)])
    }

    @Test("a broken pairing of unchanged lines is reported as one block rather than looping")
    func blocksStopOnABrokenPairing() {
        // Two unchanged lines on the left and one on the right cannot come out of the search.
        // If they ever did, the walk must still end.
        let changes = LineDiff.blocks([false, false], [false])
        #expect(changes == [change(1..<2, 1..<1)])
    }
}
