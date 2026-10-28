import Foundation
import Testing

@testable import DirnexCore

/// `ComparedDocument` and `LineEdit` over random texts and M31's corpus (PLAN.md §M33 Slice 1).
///
/// Three claims. Any sequence of edits is walked back by its inverses, and forward again by theirs.
/// Copying changes across, in any order and either way, ends with a comparison that shows none, in at
/// most as many copies as the first comparison had changed lines. And every corpus file, edited the
/// way M31's corpus edits it and written in four encodings, comes back byte for byte.
@Suite("ComparedDocument edits and copies")
struct ComparedDocumentPropertyTests {
    /// Contents short enough to repeat, with whitespace and case for the options to overlook, and an
    /// *é* written both ways, which compare as different bytes.
    private static let contents = ["a", "b", "c", "a b", "ab", " a", "a\t", "A"]
        + ["\u{E9}", "e\u{301}"]

    private static func randomLines(
        endings: [LineTerminator],
        using rng: inout SeededGenerator
    ) -> [TextLine] {
        var lines = (0..<Int.random(in: 0...12, using: &rng)).map { _ in
            TextLine(
                content: Substring(contents.randomElement(using: &rng)!),
                terminator: endings.randomElement(using: &rng)!
            )
        }
        if let last = lines.last, Int.random(in: 0..<4, using: &rng) == 0 {
            lines[lines.count - 1] = TextLine(content: last.content, terminator: .none)
        }
        return lines
    }

    private static func document(_ lines: [TextLine]) -> ComparedDocument {
        ComparedDocument(lines: lines, encoding: .utf8, hasByteOrderMark: false, isSavable: true)
    }

    /// A random edit that keeps "only the last line lacks a line break" true.
    private static func randomEdit(
        of document: ComparedDocument,
        using rng: inout SeededGenerator
    ) -> LineEdit {
        let count = document.lines.count
        var lower = Int.random(in: 0...count, using: &rng)
        let upper = Int.random(in: lower...min(count, lower + 4), using: &rng)
        var replacement = randomLines(endings: [.lf, .crlf, .cr], using: &rng)
        if upper < count, let last = replacement.last, last.terminator == .none {
            replacement[replacement.count - 1] = TextLine(content: last.content, terminator: .lf)
        }
        if !replacement.isEmpty, lower > 0, document.lines[lower - 1].terminator == .none {
            lower -= 1
        }
        return LineEdit(range: lower..<upper, replacement: replacement)
    }

    @Test("any edits are walked back by their inverses, and forward again by theirs")
    func inverses() throws {
        var rng = SeededGenerator(seed: 0x0033_0001)
        for _ in 0..<1000 {
            var document = Self.document(Self.randomLines(endings: [.lf, .crlf], using: &rng))
            let original = try document.encoded()
            var inverses: [LineEdit] = []
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                inverses.append(document.apply(Self.randomEdit(of: document, using: &rng)))
            }
            let edited = try document.encoded()
            var redos: [LineEdit] = []
            for inverse in inverses.reversed() {
                redos.append(document.apply(inverse))
            }
            #expect(try document.encoded() == original)
            #expect(!document.isEdited)
            for redo in redos.reversed() {
                document.apply(redo)
            }
            #expect(try document.encoded() == edited)
            #expect(document.isEdited == (edited != original))
        }
    }

    /// Option sets, with the line endings each pair is drawn from. Under the default options a line
    /// ending is part of the line, and a copy converts it to the destination's, so both sides share
    /// one kind there or the copies could never agree.
    private static let modes: [(options: LineDiffOptions, mixedEndings: Bool)] = [
        (LineDiffOptions(), false),
        (LineDiffOptions(ignoresLineEndings: true), true),
        (LineDiffOptions(whitespace: .ignoreAll), true),
        (LineDiffOptions(whitespace: .ignoreChanges, ignoresCase: true), true)
    ]

    @Test("copying changes either way ends in no change, and undoing every copy restores both sides")
    func copiesConverge() throws {
        var rng = SeededGenerator(seed: 0x0033_0002)
        var copies = 0
        var extended = 0
        for mode in Self.modes {
            for _ in 0..<500 {
                let kinds: [LineTerminator] = mode.mixedEndings
                    ? [.lf, .crlf, .cr]
                    : [[LineTerminator.lf], [.crlf], [.cr]].randomElement(using: &rng)!
                var left = Self.document(Self.randomLines(endings: kinds, using: &rng))
                var right = Self.document(Self.randomLines(endings: kinds, using: &rng))
                let originals = try (left.encoded(), right.encoded())
                let first = LineDiff.compare(left.lines, right.lines, options: mode.options)
                let budget = first.removedLineCount + first.insertedLineCount
                var undo: [(ComparisonPaneText.Side, LineEdit)] = []
                while undo.count <= budget {
                    let diff = LineDiff.compare(left.lines, right.lines, options: mode.options)
                    guard let change = diff.changes.randomElement(using: &rng) else { break }
                    let side: ComparisonPaneText.Side = Bool.random(using: &rng) ? .left : .right
                    let edit = LineEdit.copying(change, to: side, left: left, right: right)
                    if edit.range != (side == .left ? change.left : change.right) {
                        extended += 1
                    }
                    undo.append((side, side == .left ? left.apply(edit) : right.apply(edit)))
                }
                copies += undo.count
                #expect(
                    LineDiff.compare(left.lines, right.lines, options: mode.options).isIdentical,
                    "\(mode.options): no agreement after \(undo.count) copies, budget \(budget)"
                )
                if mode.options == LineDiffOptions() {
                    #expect(try left.encoded() == right.encoded())
                }
                for (side, inverse) in undo.reversed() {
                    if side == .left {
                        left.apply(inverse)
                    } else {
                        right.apply(inverse)
                    }
                }
                #expect(try (left.encoded(), right.encoded()) == originals)
            }
        }
        // Without these the property could hold over pairs that were mostly equal already, or
        // never reach the line that gains a break under a copy landing after it.
        #expect(copies > 3000)
        #expect(extended > 40)
    }

    @Test(
        "every corpus file and its edit come back byte for byte in four encodings, and copy across"
    )
    func corpus() throws {
        let corpus = try LineDiffGitCorpusTests.corpus()
        try #require(corpus.count > 30)
        var rng = SeededGenerator(seed: 0x0033_0003)
        let encodings: [(encoding: String.Encoding, mark: [UInt8])] = [
            (.utf8, []),
            (.utf8, [0xEF, 0xBB, 0xBF]),
            (.utf16LittleEndian, [0xFF, 0xFE]),
            (.utf16BigEndian, [0xFE, 0xFF])
        ]
        var copied = 0
        for url in corpus {
            let original = try String(contentsOf: url, encoding: .utf8)
            let edited = LineDiffGitCorpusTests.edit(original, using: &rng)
            for text in [original, edited] {
                for encoding in encodings {
                    let data = try Data(encoding.mark) + #require(
                        text.data(using: encoding.encoding)
                    )
                    let document = try ComparedDocument.decode(data)
                    #expect(document.isSavable, "\(url.lastPathComponent) \(encoding.encoding)")
                    #expect(try document.encoded() == data)
                }
            }
            // Every change copied from the original into its edit gives the original back. The
            // edit's CRLF lines are a minority, so the copies land as LF, as the original has them.
            let left = try ComparedDocument.decode(Data(original.utf8))
            var right = try ComparedDocument.decode(Data(edited.utf8))
            try #require(right.commonLineEnding == .lf)
            let first = LineDiff.compare(left.lines, right.lines)
            for _ in 0...first.changes.count {
                guard let change = LineDiff.compare(left.lines, right.lines).changes.first else {
                    break
                }
                right.apply(LineEdit.copying(change, to: .right, left: left, right: right))
                copied += 1
            }
            #expect(try right.encoded() == Data(original.utf8), "\(url.lastPathComponent)")
        }
        #expect(copied > 150)
    }
}
