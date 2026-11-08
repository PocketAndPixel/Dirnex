import Foundation
import Testing

@testable import DirnexCore

/// What carrying one side's whitespace onto the other's edit keeps true, over random texts and with
/// no git (PLAN.md §M37 Slice 5): the edit survives, apart from whitespace, line for line; a line the
/// edit kept as the base had it takes the other side's whitespace exactly; and a merge whose
/// conflicts take it stays whole and level, as every other choice keeps it.
@Suite("ConflictWhitespace properties")
struct ConflictWhitespacePropertyTests {
    /// Random whitespace, line content and endings, for the texts below.
    struct Lines {
        var rng: SeededGenerator
        private var next = 0

        init(seed: UInt64) {
            rng = SeededGenerator(seed: seed)
        }

        mutating func indent() -> String {
            ["", "", "  ", "    ", "\t", "\t\t", "      "].randomElement(using: &rng) ?? ""
        }

        mutating func trailing() -> String {
            Int.random(in: 0..<5, using: &rng) == 0 ? [" ", "\t", "  "].randomElement(using: &rng) ?? "" : ""
        }

        mutating func ending() -> String {
            Int.random(in: 0..<5, using: &rng) == 0 ? "\r\n" : "\n"
        }

        /// Text no other line has, so the comparisons below pair lines one way only.
        mutating func uniqueText() -> String {
            next += 1
            return "line \(next) " + (Bool.random(using: &rng) ? "x = y" : "call(a,  b)")
        }

        /// A part of a line as text: always UTF-8, being cut from a line at ASCII bytes.
        static func string(_ bytes: [UInt8]) -> String {
            String(bytes: bytes, encoding: .utf8) ?? ""
        }

        /// One line, with its ending.
        mutating func line(text: String) -> String {
            indent() + text + trailing() + ending()
        }

        /// `line` with only its whitespace changed: its indentation, the spacing after its text, or
        /// its ending, one or more of them. Its text is kept byte for byte.
        mutating func respaced(_ line: TextLine) -> String {
            let parts = LineParts(line)
            let text = Self.string(parts.text)
            var indent = Self.string(parts.indent)
            var trailing = Self.string(parts.trailing)
            var ending = line.terminator.text
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: indent = "  " + indent
            case 1: indent = indent.replacingOccurrences(of: "\t", with: "    ")
            case 2: trailing = trailing.isEmpty ? " " : ""
            case 3: ending = ending == "\r\n" ? "\n" : "\r\n"
            default: indent = String(indent.dropFirst(min(2, indent.count)))
            }
            if text.isEmpty { trailing = "" }
            return indent + text + trailing + ending
        }
    }

    private static func split(_ lines: [String]) -> [TextLine] {
        TextLines.split(lines.joined())
    }

    private static let spacing = LineDiffOptions(whitespace: .ignoreAll)

    @Test(
        "the edit survives but for whitespace, and every line it kept takes the other side's exactly"
    )
    func carryKeepsBothEdits() {
        var lines = Lines(seed: 0x0037_0005)
        var carried = 0
        var refused = 0
        var keptLines = 0
        for trial in 0..<3000 {
            let baseText = (0..<Int.random(in: 1...12, using: &lines.rng)).map { _ in
                lines.line(text: lines.uniqueText())
            }
            let base = Self.split(baseText)
            // Each line respaced or left alone, line for line.
            let spacing = Self.split(base.map { line in
                Int.random(in: 0..<3, using: &lines.rng) == 0
                    ? lines.respaced(line) : String(line.content) + line.terminator.text
            })
            // The edit: each base line kept, edited, dropped, or given a new line before it. A kept
            // line is remembered by where it lands.
            var edit: [String] = []
            var kept: [(edit: Int, base: Int)] = []
            for (index, line) in base.enumerated() {
                if Int.random(in: 0..<5, using: &lines.rng) == 0 {
                    edit.append(lines.line(text: lines.uniqueText()))
                }
                switch Int.random(in: 0..<6, using: &lines.rng) {
                case 0:
                    break
                case 1, 2:
                    // Its text, and now and then its indentation too.
                    let parts = LineParts(line)
                    let indent = Bool.random(using: &lines.rng) ? lines.indent() : Lines.string(
                        parts.indent
                    )
                    edit.append(indent + lines.uniqueText() + Lines.string(parts.trailing) + "\n")
                default:
                    kept.append((edit.count, index))
                    edit.append(
                        String(line.content) + (
                            line.terminator == .none ? "\n" : line.terminator.text
                        )
                    )
                }
            }
            let editLines = Self.split(edit)
            let context = "trial \(trial): \([baseText.joined(), edit.joined()])"
            guard let result = WhitespaceCarry.carry(spacing: spacing, base: base, onto: editLines) else {
                refused += 1
                continue
            }
            carried += 1
            #expect(result.count == editLines.count, "\(context)")
            #expect(result.map(Self.spacing.key) == editLines.map(Self.spacing.key), "\(context)")
            for (editIndex, baseIndex) in kept {
                #expect(result[editIndex] == spacing[baseIndex], "\(context) line \(editIndex)")
                keptLines += 1
            }
            #expect(WhitespaceCarry.carry(spacing: base, base: base, onto: editLines) == editLines)
            #expect(WhitespaceCarry.carry(spacing: spacing, base: base, onto: base) == spacing)
        }
        // Without these, the checks could have held over runs that never carried, or never refused.
        #expect(carried >= 1500)
        #expect(refused >= 200)
        #expect(keptLines >= 5000)
    }

    @Test(
        "any sequence of choices, the whitespace take among them, keeps every column whole and level"
    )
    func takeKeepsTheLayout() {
        var lines = Lines(seed: 0x0037_0006)
        var kinds: [ConflictWhitespace.Kind: Int] = [:]
        var offered = 0
        var taken = 0
        for trial in 0..<2000 {
            // Few distinct texts, so changes touch and conflict often.
            let texts = ["a", "b = c", "d(e)"]
            let base = (0..<Int.random(in: 0...10, using: &lines.rng)).map { _ in
                lines.line(text: texts.randomElement(using: &lines.rng) ?? "a")
            }
            let respaced = Self.split(base).map { lines.respaced($0) }
            func edited(_ text: [String]) -> [String] {
                var text = text
                for _ in 0..<Int.random(in: 1...3, using: &lines.rng) {
                    let start = Int.random(in: 0...text.count, using: &lines.rng)
                    let end = min(text.count, start + Int.random(in: 0...2, using: &lines.rng))
                    let count = Int.random(in: 0...2, using: &lines.rng)
                    text.replaceSubrange(start..<end, with: (0..<count).map { _ in
                        lines.line(
                            text: (texts + ["f!", "g"]).randomElement(using: &lines.rng) ?? "g"
                        )
                    })
                }
                return text
            }
            // One side respaced, the other edited, either way round; now and then both respaced.
            let sides = switch Int.random(in: 0..<5, using: &lines.rng) {
            case 0: (respaced, edited(base))
            case 1: (edited(base), respaced)
            case 2: (respaced, Self.split(base).map { lines.respaced($0) })
            default: (edited(base), edited(base))
            }
            var merge = TextMerge(
                base: TextMergeTests.document(base.joined()),
                yours: TextMergeTests.document(sides.0.joined()),
                theirs: TextMergeTests.document(sides.1.joined())
            )
            let context = "trial \(trial): \([base.joined(), sides.0.joined(), sides.1.joined()])"
            for (conflict, whitespace) in merge.whitespace.enumerated() {
                guard let whitespace else { continue }
                kinds[whitespace.kind, default: 0] += 1
                if merge.offers(.editWithWhitespace, forConflict: conflict) { offered += 1 }
            }
            for _ in 0..<min(4, merge.choices.count) {
                let conflict = Int.random(in: 0..<merge.choices.count, using: &lines.rng)
                let choices = TextMerge.Choice.allCases.filter { merge.offers(
                    $0,
                    forConflict: conflict
                ) }
                let choice = choices.contains(.editWithWhitespace) && Bool.random(using: &lines.rng)
                    ? .editWithWhitespace : choices.randomElement(using: &lines.rng)
                merge.apply(TextMerge.Step(conflict: conflict, choice: choice))
                if choice == .editWithWhitespace { taken += 1 }
                TextMergePropertyTests.check(merge, "\(context) after \(String(describing: choice))")
            }
        }
        #expect(kinds[.yoursOnlyWhitespace, default: 0] >= 150, "\(kinds)")
        #expect(kinds[.theirsOnlyWhitespace, default: 0] >= 150, "\(kinds)")
        #expect(kinds[.sidesDifferOnlyInWhitespace, default: 0] >= 150, "\(kinds)")
        #expect(offered >= 250)
        #expect(taken >= 150)
    }
}
