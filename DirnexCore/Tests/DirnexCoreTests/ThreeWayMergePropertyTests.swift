import Foundation
import Testing

@testable import DirnexCore

/// What any three-way merge has to do, checked over random texts with no git involved (PLAN.md
/// §M34 Slice 1). Merging a text with itself gives it back, a side left as the base yields the
/// other side, and every change only one side made is in the result, however the conflicts around
/// it are taken.
@Suite("ThreeWayMerge properties")
struct ThreeWayMergePropertyTests {
    /// A short text over a few distinct lines, a few of them ending in CRLF, and now and then one
    /// with no final line break.
    private static func randomLines(using rng: inout SeededGenerator) -> [TextLine] {
        let alphabet = Int.random(in: 1...4, using: &rng)
        var lines = (0..<Int.random(in: 0...12, using: &rng)).map { _ in
            TextLine(
                content: Substring(String(Int.random(in: 0..<alphabet, using: &rng))),
                terminator: Int.random(in: 0..<6, using: &rng) == 0 ? .crlf : .lf
            )
        }
        if let last = lines.last, Int.random(in: 0..<4, using: &rng) == 0 {
            lines[lines.count - 1] = TextLine(content: last.content, terminator: .none)
        }
        return lines
    }

    /// `lines` with a few runs replaced by others drawn the same way.
    private static func edited(_ lines: [TextLine], using rng: inout SeededGenerator) -> [TextLine] {
        var lines = lines
        for _ in 0..<Int.random(in: 0...3, using: &rng) {
            let start = Int.random(in: 0...lines.count, using: &rng)
            let end = min(lines.count, start + Int.random(in: 0...3, using: &rng))
            let replacement = randomLines(using: &rng).prefix(3)
            lines.replaceSubrange(start..<end, with: replacement)
        }
        // Only a file's last line may lack a line break.
        for index in lines.indices.dropLast() where lines[index].terminator == .none {
            lines[index] = TextLine(content: lines[index].content, terminator: .lf)
        }
        return lines
    }

    private static func bytes(_ lines: some Sequence<TextLine>) -> [UInt8] {
        lines.flatMap { Array($0.content.utf8) + Array($0.terminator.text.utf8) }
    }

    private static func merge(_ base: [TextLine], _ yours: [TextLine], _ theirs: [TextLine]) -> ThreeWayMerge {
        ThreeWayMerge.merge(
            base: base,
            yours: yours,
            theirs: theirs,
            options: LineDiffOptions(isMinimal: true)
        )
    }

    @Test("a text merged with itself comes back, and a side left as the base yields the other")
    func trivialMerges() throws {
        var rng = SeededGenerator(seed: 0x0034_0003)
        for _ in 0..<2000 {
            let base = Self.randomLines(using: &rng)
            let other = Self.edited(base, using: &rng)
            // Each case's sides, and what merging them has to give.
            let cases: [String: [[TextLine]]] = [
                "itself": [base, base, base],
                "yours left as the base": [base, other, other],
                "theirs left as the base": [other, base, other],
                "the same edit on both sides": [other, other, other]
            ]
            for (name, sides) in cases {
                let (yours, theirs, expected) = (sides[0], sides[1], sides[2])
                let merge = Self.merge(base, yours, theirs)
                let merged = try #require(merge.mergedLines(yours: yours, theirs: theirs), "\(name)")
                #expect(Self.bytes(merged) == Self.bytes(expected), "\(name): \(base) \(sides)")
            }
            #expect(Self.merge(base, base, base).regions.allSatisfy { $0.kind == .unchanged })
        }
    }

    @Test("the regions tile all three texts, and each kind says what its lines show")
    func regionsTile() {
        var rng = SeededGenerator(seed: 0x0034_0004)
        var kinds: [ThreeWayMerge.Kind: Int] = [:]
        for _ in 0..<3000 {
            let base = Self.randomLines(using: &rng)
            let yours = Self.edited(base, using: &rng)
            let theirs = Self.edited(Bool.random(using: &rng) ? yours : base, using: &rng)
            let merge = Self.merge(base, yours, theirs)
            var next = (base: 0, yours: 0, theirs: 0)
            for region in merge.regions {
                #expect(region.base.lowerBound == next.base && region.yours.lowerBound == next.yours
                    && region.theirs.lowerBound == next.theirs)
                next = (region.base.upperBound, region.yours.upperBound, region.theirs.upperBound)
                kinds[region.kind, default: 0] += 1
                let baseBytes = Self.bytes(base[region.base])
                let yoursBytes = Self.bytes(yours[region.yours])
                let theirsBytes = Self.bytes(theirs[region.theirs])
                switch region.kind {
                case .unchanged:
                    #expect(yoursBytes == baseBytes && theirsBytes == baseBytes)
                case .yours:
                    #expect(theirsBytes == baseBytes && yoursBytes != baseBytes)
                case .theirs:
                    #expect(yoursBytes == baseBytes && theirsBytes != baseBytes)
                case .same:
                    #expect(yoursBytes == theirsBytes)
                case .conflict:
                    #expect(yoursBytes != theirsBytes, "\(base) \(yours) \(theirs)")
                }
            }
            #expect(next == (base.count, yours.count, theirs.count))
            if let merged = merge.mergedLines(yours: yours, theirs: theirs) {
                // A line with no break can only be the last, or it would join the next one.
                #expect(merged.dropLast().allSatisfy { $0.terminator != .none })
            }
        }
        // Each kind has to have come up, or the checks above held over nothing.
        for kind in [ThreeWayMerge.Kind.unchanged, .yours, .theirs, .same, .conflict] {
            #expect(kinds[kind, default: 0] >= 300, "\(kind): \(kinds[kind, default: 0])")
        }
    }

    /// One place in the base that a side edits: `range` gives way to `replacement`.
    private struct Edit {
        let range: Range<Int>
        let replacement: [TextLine]
    }

    /// Whether two edits of the base overlap or touch, which makes them one conflict.
    private static func meet(_ edit: Edit, _ other: Edit) -> Bool {
        edit.range.overlaps(other.range) || edit.range == other.range
            || edit.range.upperBound == other.range.lowerBound
            || other.range.upperBound == edit.range.lowerBound
    }

    /// `base` with `edits`, which must not overlap, applied.
    private static func applying(_ edits: [Edit], to base: [TextLine]) -> [TextLine] {
        var lines = base
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            lines.replaceSubrange(edit.range, with: edit.replacement)
        }
        return lines
    }

    @Test("every change only one side made is in the result, whichever way the conflicts are taken")
    func oneSidedChangesSurvive() throws {
        var rng = SeededGenerator(seed: 0x0034_0005)
        var fresh = 0
        // Lines no other line equals, so each comparison has one answer and an edit is where it was
        // made, rather than wherever an equal line lets it slide.
        func unique(_ count: Int) -> [TextLine] {
            (0..<count).map { _ in
                fresh += 1
                return TextLine(content: Substring("line \(fresh)"), terminator: .lf)
            }
        }
        var conflicts = 0
        var oneSided = 0
        for _ in 0..<1000 {
            let base = unique(Int.random(in: 0...30, using: &rng))
            var yoursEdits: [Edit] = []
            var theirsEdits: [Edit] = []
            var expectedConflicts = 0
            // Places at least one untouched line apart, each edited by one side, by both, or
            // touched by both with no line between them.
            var start = Int.random(in: 0...2, using: &rng)
            while start <= base.count {
                let length = min(Int.random(in: 0...3, using: &rng), base.count - start)
                let range = start..<start + length
                switch Int.random(in: 0..<5, using: &rng) {
                case 0:
                    yoursEdits.append(
                        Edit(range: range, replacement: unique(Int.random(in: 1...3, using: &rng)))
                    )
                case 1:
                    theirsEdits.append(
                        Edit(range: range, replacement: unique(Int.random(in: 1...3, using: &rng)))
                    )
                case 2:
                    // Yours may delete what theirs replaces, but an empty place needs a line.
                    let count = Int.random(in: (range.isEmpty ? 1 : 0)...3, using: &rng)
                    yoursEdits.append(Edit(range: range, replacement: unique(count)))
                    theirsEdits.append(
                        Edit(range: range, replacement: unique(Int.random(in: 1...3, using: &rng)))
                    )
                    expectedConflicts += 1
                case 3 where length >= 2:
                    let middle = range.lowerBound + length / 2
                    yoursEdits.append(Edit(range: range.lowerBound..<middle, replacement: unique(1)))
                    theirsEdits.append(
                        Edit(range: middle..<range.upperBound, replacement: unique(1))
                    )
                    expectedConflicts += 1
                default:
                    break
                }
                start = range.upperBound + 1 + Int.random(in: 0...2, using: &rng)
            }
            let yours = Self.applying(yoursEdits, to: base)
            let theirs = Self.applying(theirsEdits, to: base)
            let merge = Self.merge(base, yours, theirs)
            #expect(merge.conflictCount == expectedConflicts)
            conflicts += expectedConflicts

            // Taking yours in every conflict leaves yours and every change only theirs made.
            let theirsOnly = theirsEdits.filter { edit in !yoursEdits.contains { Self.meet($0, edit) } }
            let yoursOnly = yoursEdits.filter { edit in !theirsEdits.contains { Self.meet($0, edit) } }
            oneSided += theirsOnly.count + yoursOnly.count
            let takingYours = merge.regions.flatMap { region in
                region.kind == .theirs ? theirs[region.theirs] : yours[region.yours]
            }
            let takingTheirs = merge.regions.flatMap { region in
                region.kind == .yours ? yours[region.yours] : theirs[region.theirs]
            }
            #expect(takingYours == Self.applying(yoursEdits + theirsOnly, to: base))
            #expect(takingTheirs == Self.applying(theirsEdits + yoursOnly, to: base))
            if expectedConflicts == 0 {
                let merged = try #require(merge.mergedLines(yours: yours, theirs: theirs))
                #expect(merged == Self.applying(yoursEdits + theirsEdits, to: base))
            }
        }
        #expect(conflicts >= 500)
        #expect(oneSided >= 1500)
    }
}
