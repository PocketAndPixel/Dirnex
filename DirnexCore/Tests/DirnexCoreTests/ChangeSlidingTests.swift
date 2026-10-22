import Foundation
import Testing

@testable import DirnexCore

/// Where a block of changed lines lands when it could sit in more than one place (PLAN.md §M31
/// Slice 2). Every expected block is git's own answer, from
/// `git diff --no-index -U0 --diff-algorithm=minimal --indent-heuristic`, probed with git 2.54 on
/// 2026-10-22.
@Suite("ChangeSliding")
struct ChangeSlidingTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let left: String
        let right: String
        let left0: Range<Int>
        let right0: Range<Int>
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "a function inserted between two others runs from its signature to the blank line",
            left: "func a() {\n    x\n}\n\nfunc c() {\n    z\n}\n",
            right: "func a() {\n    x\n}\n\nfunc b() {\n    y\n}\n\nfunc c() {\n    z\n}\n",
            left0: 4..<4, right0: 4..<8
        ),
        Case(
            name: "a function appended at the end of the file starts with its blank line",
            left: "func a() {\n}\n",
            right: "func a() {\n}\n\nfunc b() {\n}\n",
            left0: 2..<2, right0: 2..<5
        ),
        Case(
            name: "a duplicated if-block is the second one, not a rotation through the braces",
            left: "    if a {\n        foo()\n    }\n}\n",
            right: "    if a {\n        foo()\n    }\n    if b {\n        foo()\n    }\n}\n",
            left0: 3..<3, right0: 3..<6
        ),
        Case(
            name: "one more of many identical lines goes last",
            left: "x\nx\nx\nx\n",
            right: "x\nx\nx\nx\nx\n",
            left0: 4..<4, right0: 4..<5
        ),
        Case(
            name: "an extra blank line between paragraphs goes last",
            left: "para one\n\npara two\n",
            right: "para one\n\n\npara two\n",
            left0: 2..<2, right0: 2..<3
        ),
        Case(
            name: "a documented function starts at its comment",
            left: "/// Doc a\nfunc a()\n\n/// Doc c\nfunc c()\n",
            right: "/// Doc a\nfunc a()\n\n/// Doc b\nfunc b()\n\n/// Doc c\nfunc c()\n",
            left0: 3..<3, right0: 3..<6
        ),
        Case(
            // The lowest position would be `a`, blank, `b`; both of its boundaries cut a paragraph.
            name: "a repeated paragraph ends at a paragraph break rather than at the lowest position",
            left: "1\n2\na\n\nb\n3\n4\n",
            right: "1\n2\na\n\nb\na\n\nb\n3\n4\n",
            left0: 4..<4, right0: 4..<7
        ),
        Case(
            name: "a method appended to a type runs from the blank line to its own closing brace",
            left: "class A {\n    func x() {\n        one()\n    }\n}\n",
            right: "class A {\n    func x() {\n        one()\n    }\n\n    func y() {\n        one()\n    }\n}\n",
            left0: 4..<4, right0: 4..<8
        ),
        Case(
            name: "a repeated indented paragraph goes last",
            left: "a\n\n    b\n    c\n\nd\n",
            right: "a\n\n    b\n    c\n\n    b\n    c\n\nd\n",
            left0: 5..<5, right0: 5..<8
        ),
        Case(
            name: "a C function inserted runs from its signature to the blank line",
            left: "    foo();\n}\n\nvoid g() {\n    foo();\n}\n",
            right: "    foo();\n}\n\nvoid h() {\n    foo();\n}\n\nvoid g() {\n    foo();\n}\n",
            left0: 3..<3, right0: 3..<7
        ),
        Case(
            name: "a Markdown section starts at its heading",
            left: "  - one\n  - two\n\n## Next\n",
            right: "  - one\n  - two\n\n## New\n\n  - two\n\n## Next\n",
            left0: 3..<3, right0: 3..<7
        ),
        Case(
            name: "a method appended inside a struct keeps the type's closing brace out",
            left: "struct S {\n    func a() {\n        one()\n    }\n}\n",
            right: "struct S {\n    func a() {\n        one()\n    }\n\n    func b() {\n        one()\n    }\n}\n",
            left0: 4..<4, right0: 4..<8
        ),
        Case(
            name: "an insertion next to a replacement stays with it, as one block",
            left: "x\nA\nx\ny\n",
            right: "x\nB\nx\nx\ny\n",
            left0: 1..<2, right0: 1..<3
        ),
        Case(
            name: "a removed method ends at its blank line, before the mark that follows",
            left: "    }\n\n    func b() {\n        two()\n    }\n\n    // MARK: - end\n",
            right: "    }\n\n    // MARK: - end\n",
            left0: 2..<6, right0: 2..<2
        )
    ]

    @Test("each block lands where git puts it", arguments: cases)
    func landsWhereGitPutsIt(_ testCase: Case) {
        let diff = LineDiff.compare(
            testCase.left,
            testCase.right,
            options: LineDiffOptions(isMinimal: true)
        )
        #expect(diff.changes == [LineDiff.Change(left: testCase.left0, right: testCase.right0)])
    }

    @Test("blank lines and indentation make a line's shape, and a tab counts four columns")
    func lineShape() {
        let blank = ChangeSliding.LineShape(" \t ")
        #expect(blank.isBlank)
        #expect(blank.indent == 0)
        let nested = ChangeSliding.LineShape("\t  return")
        #expect(!nested.isBlank)
        #expect(nested.indent == 6)
    }

    @Test("sliding keeps every count and every pairing valid, on 500 random texts")
    func slidingKeepsTheAnswer() {
        var rng = SeededGenerator(seed: 0x0031_0005)
        let vocabulary = ["", "}", "    }", "func f() {", "    x", "        y", "a", "b"]
        func text() -> String {
            (0..<Int.random(in: 0...30, using: &rng))
                .map { _ in vocabulary[Int.random(in: 0..<vocabulary.count, using: &rng)] + "\n" }
                .joined()
        }
        for _ in 0..<500 {
            let left = text()
            let right = text()
            let leftLines = TextLines.split(left).map { String($0.content) }
            let rightLines = TextLines.split(right).map { String($0.content) }
            let diff = LineDiff.compare(left, right, options: LineDiffOptions(isMinimal: true))
            var keptLeft = Array(repeating: true, count: leftLines.count)
            var keptRight = Array(repeating: true, count: rightLines.count)
            for change in diff.changes {
                change.left.forEach { keptLeft[$0] = false }
                change.right.forEach { keptRight[$0] = false }
            }
            let unchangedLeft = leftLines.indices.filter { keptLeft[$0] }.map { leftLines[$0] }
            let unchangedRight = rightLines.indices.filter { keptRight[$0] }.map { rightLines[$0] }
            #expect(
                unchangedLeft == unchangedRight,
                "\(left.debugDescription) → \(right.debugDescription)"
            )
            let ids = Dictionary(
                (leftLines + rightLines).map { ($0, Int32(vocabulary.firstIndex(of: $0) ?? -1)) },
                uniquingKeysWith: { first, _ in first }
            )
            let lcs = LineDiffPropertyTests.lcsLength(
                leftLines.compactMap { ids[$0] },
                rightLines.compactMap { ids[$0] }
            )
            #expect(
                diff.removedLineCount + diff.insertedLineCount == leftLines.count + rightLines.count - 2 * lcs
            )
        }
    }
}
