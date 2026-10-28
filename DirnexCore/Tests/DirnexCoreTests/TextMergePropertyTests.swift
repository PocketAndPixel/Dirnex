import Foundation
import Testing

@testable import DirnexCore

/// What the merge window's model has to keep true however its conflicts are chosen, over random
/// texts and random choices (PLAN.md §M34 Slice 2): every column shows each of its lines once, in
/// order; the result's lines sit level with the lines they came from; the result is what the
/// regions and the choices say it is; and undoing every step gives the merge back as it opened.
@Suite("TextMerge properties")
struct TextMergePropertyTests {
    /// A short text over a few distinct lines, a few ending in CRLF, some with no final line break.
    private static func randomText(using rng: inout SeededGenerator) -> String {
        let alphabet = Int.random(in: 1...4, using: &rng)
        var lines = (0..<Int.random(in: 0...12, using: &rng)).map { _ in
            "\(Int.random(in: 0..<alphabet, using: &rng))"
                + (Int.random(in: 0..<6, using: &rng) == 0 ? "\r\n" : "\n")
        }
        if let last = lines.last, Int.random(in: 0..<4, using: &rng) == 0 {
            lines[lines.count - 1] = last.trimmingCharacters(in: .newlines)
        }
        return lines.joined()
    }

    /// `text` with a few runs of lines replaced by others drawn the same way.
    private static func edited(_ text: String, using rng: inout SeededGenerator) -> String {
        var lines = TextLines.split(text).map { String($0.content) + $0.terminator.text }
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            let start = Int.random(in: 0...lines.count, using: &rng)
            let end = min(lines.count, start + Int.random(in: 0...3, using: &rng))
            let replacement = TextLines.split(randomText(using: &rng)).prefix(3)
                .map { String($0.content) + ($0.terminator == .none ? "\n" : $0.terminator.text) }
            lines.replaceSubrange(start..<end, with: replacement)
        }
        // Only a file's last line may lack a line break.
        for index in lines.indices.dropLast() where !lines[index].hasSuffix("\n") {
            lines[index] += "\n"
        }
        return lines.joined()
    }

    private static func bytes(_ line: TextLine) -> [UInt8] {
        Array(line.content.utf8) + Array(line.terminator.text.utf8)
    }

    /// The result the regions and the choices call for, built without `TextMerge`.
    private static func expectedResult(_ merge: TextMerge) -> [[UInt8]] {
        var conflict = 0
        var lines: [TextLine] = []
        for region in merge.merge.regions {
            let yours = Array(merge.yours.lines[region.yours])
            let theirs = Array(merge.theirs.lines[region.theirs])
            switch region.kind {
            case .unchanged, .yours, .same:
                lines += yours
            case .theirs:
                lines += theirs
            case .conflict:
                let choice = merge.choices[conflict]
                conflict += 1
                let parts: [[TextLine]] = switch choice {
                case nil: []
                case .yours: [yours]
                case .theirs: [theirs]
                case .yoursThenTheirs: [yours, theirs]
                case .theirsThenYours: [theirs, yours]
                }
                var first = parts.first ?? []
                if parts.count == 2, !parts[1].isEmpty, let last = first.last, last.terminator == .none {
                    let ending = merge.yours.commonLineEnding ?? merge.theirs.commonLineEnding ?? .lf
                    first[first.count - 1] = TextLine(content: last.content, terminator: ending)
                }
                lines += first + (parts.count == 2 ? parts[1] : [])
            }
        }
        return lines.map(bytes)
    }

    /// Every check that does not depend on how the merge got here.
    private static func check(_ merge: TextMerge, _ context: String) {
        #expect(merge.result.lines.map(bytes) == expectedResult(merge), "\(context)")
        #expect(merge.result.lines.dropLast().allSatisfy { $0.terminator != .none }, "\(context)")
        let counts: [MergeRow.Column: Int] = [
            .yours: merge.yours.lines.count,
            .theirs: merge.theirs.lines.count,
            .base: merge.base.lines.count,
            .result: merge.result.lines.count
        ]
        for (column, count) in counts {
            // Each line once, in order, on some row.
            #expect(
                merge.rows.compactMap { $0.line(in: column) } == Array(0..<count),
                "\(column) \(context)"
            )
            #expect(merge.paneText(for: column).rowStarts.count == merge.rows.count)
        }
        #expect(
            merge.rows.allSatisfy { row in MergeRow.Column.allCases.contains { row.line(in: $0) != nil } }
        )
        #expect(merge.rows.map(\.region) == merge.rows.map(\.region).sorted(), "\(context)")
        let conflictRegions = merge.merge.regions.indices.filter { merge.merge.regions[$0].kind == .conflict }
        #expect(merge.conflictRows.count == conflictRegions.count)
        for (conflict, region) in conflictRegions.enumerated() {
            let rows = merge.rows.indices.filter { merge.rows[$0].region == region }
            #expect(rows == Array(merge.conflictRows[conflict]), "\(context)")
        }
        // A result line sits on the row of the line it came from.
        var conflict = 0
        for (index, region) in merge.merge.regions.enumerated() {
            let rows = merge.rows.filter { $0.region == index }
            let choice: TextMerge.Choice? = region.kind == .conflict ? merge.choices[conflict] : nil
            if region.kind == .conflict {
                conflict += 1
            }
            let source: MergeRow.Column? = switch (region.kind, choice) {
            case (.theirs, _), (.conflict, .theirs?), (.conflict, .theirsThenYours?): .theirs
            case (.conflict, nil): nil
            default: .yours
            }
            guard let source else {
                #expect(rows.allSatisfy { $0.result == nil }, "\(context)")
                continue
            }
            let lines = source == .yours ? merge.yours.lines : merge.theirs.lines
            let firstPart = rows.filter { $0.line(in: source) != nil }
            for row in firstPart {
                // The content: taking both may have given the line a break it did not have.
                let shown = row.result.map { merge.result.lines[$0].content }
                let from = row.line(in: source).map { lines[$0].content }
                #expect(shown != nil && shown == from, "\(context)")
            }
            // Both sides taken: the second side's lines come after the first's, never beside them.
            if choice == .yoursThenTheirs || choice == .theirsThenYours,
               let lastOfFirst = rows.lastIndex(where: { $0.line(in: source) != nil }) {
                #expect(
                    rows[..<lastOfFirst].filter { $0.result != nil }.count == firstPart.count - 1
                )
            }
        }
    }

    @Test("any sequence of choices keeps every column whole and level, and undoes back to the start")
    func choicesKeepTheLayout() {
        var rng = SeededGenerator(seed: 0x0034_0006)
        var steps = 0
        var conflicted = 0
        for trial in 0..<2000 {
            let base = Self.randomText(using: &rng)
            let yours = Self.edited(base, using: &rng)
            let theirs = Self.edited(Bool.random(using: &rng) ? yours : base, using: &rng)
            var merge = TextMerge(
                base: TextMergeTests.document(base),
                yours: TextMergeTests.document(yours),
                theirs: TextMergeTests.document(theirs)
            )
            let opened = merge
            let context = "trial \(trial): \([base, yours, theirs])"
            Self.check(merge, context)
            guard !merge.choices.isEmpty else { continue }
            conflicted += 1
            var undo: [TextMerge.Step] = []
            for _ in 0..<Int.random(in: 1...8, using: &rng) {
                // An open choice now and then, so a conflict is reopened as well as chosen again.
                let choice = Int.random(in: 0..<5, using: &rng) == 0
                    ? nil : TextMerge.Choice.allCases.randomElement(using: &rng)
                let conflict = Int.random(in: 0..<merge.choices.count, using: &rng)
                let step = TextMerge.Step(conflict: conflict, choice: choice)
                undo.append(merge.apply(step))
                Self.check(merge, "\(context) after \(step)")
                steps += 1
            }
            for step in undo.reversed() {
                merge.apply(step)
            }
            #expect(merge.choices == opened.choices)
            #expect(merge.rows == opened.rows, "\(context)")
            #expect(merge.result.lines.map(Self.bytes) == opened.result.lines.map(Self.bytes))
        }
        // Without these, the checks above could have held over merges that never conflicted.
        #expect(conflicted >= 500)
        #expect(steps >= 2000)
    }
}
