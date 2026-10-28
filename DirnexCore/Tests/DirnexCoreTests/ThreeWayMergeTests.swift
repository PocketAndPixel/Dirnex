import Foundation
import Testing

@testable import DirnexCore

/// The regions of a three-way merge, case by case (PLAN.md §M34 Slice 1). Every expected answer is
/// `git merge-file --diff3` or `--zdiff3`'s, probed with git 2.54 on 2026-10-26.
@Suite("ThreeWayMerge")
struct ThreeWayMergeTests {
    typealias Region = ThreeWayMerge.Region

    private static func merge(
        _ base: String,
        _ yours: String,
        _ theirs: String,
        trimsConflicts: Bool = true
    ) -> ThreeWayMerge {
        ThreeWayMerge.merge(
            base: TextLines.split(base),
            yours: TextLines.split(yours),
            theirs: TextLines.split(theirs),
            options: LineDiffOptions(),
            trimsConflicts: trimsConflicts
        )
    }

    private static func merged(_ base: String, _ yours: String, _ theirs: String) -> String? {
        let yoursLines = TextLines.split(yours)
        let theirsLines = TextLines.split(theirs)
        let lines = merge(base, yours, theirs).mergedLines(yours: yoursLines, theirs: theirsLines)
        return lines?.map { String($0.content) + $0.terminator.text }.joined()
    }

    @Test("one unchanged base line between two changes lets both merge")
    func oneLineApart() {
        let merge = Self.merge("a\nb\nc\n", "X\nb\nc\n", "a\nb\nY\n")
        #expect(merge.regions == [
            Region(kind: .yours, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .unchanged, base: 1..<2, yours: 1..<2, theirs: 1..<2),
            Region(kind: .theirs, base: 2..<3, yours: 2..<3, theirs: 2..<3)
        ])
        #expect(merge.isClean)
        #expect(Self.merged("a\nb\nc\n", "X\nb\nc\n", "a\nb\nY\n") == "X\nb\nY\n")
    }

    @Test("changes that touch, with no unchanged base line between them, are one conflict")
    func touchingChanges() {
        let merge = Self.merge("a\nb\nc\n", "X\nb\nc\n", "a\nY\nc\n")
        #expect(merge.regions == [
            Region(kind: .conflict, base: 0..<2, yours: 0..<2, theirs: 0..<2),
            Region(kind: .unchanged, base: 2..<3, yours: 2..<3, theirs: 2..<3)
        ])
        #expect(merge.conflictCount == 1)
        #expect(Self.merged("a\nb\nc\n", "X\nb\nc\n", "a\nY\nc\n") == nil)
    }

    @Test("two insertions at one place conflict, and the same insertion is taken once")
    func insertions() {
        #expect(Self.merge("a\nb\n", "a\nX\nb\n", "a\nY\nb\n").regions == [
            Region(kind: .unchanged, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .conflict, base: 1..<1, yours: 1..<2, theirs: 1..<2),
            Region(kind: .unchanged, base: 1..<2, yours: 2..<3, theirs: 2..<3)
        ])
        #expect(Self.merge("a\nb\n", "a\nX\nb\n", "a\nX\nb\n").regions == [
            Region(kind: .unchanged, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .same, base: 1..<1, yours: 1..<2, theirs: 1..<2),
            Region(kind: .unchanged, base: 1..<2, yours: 2..<3, theirs: 2..<3)
        ])
        #expect(Self.merged("a\nb\n", "a\nX\nb\n", "a\nX\nb\n") == "a\nX\nb\n")
    }

    @Test("a deletion against an edit of the same line conflicts")
    func deletionAgainstEdit() {
        #expect(Self.merge("a\nb\nc\n", "a\nc\n", "a\nB\nc\n").regions == [
            Region(kind: .unchanged, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .conflict, base: 1..<2, yours: 1..<1, theirs: 1..<2),
            Region(kind: .unchanged, base: 2..<3, yours: 1..<2, theirs: 2..<3)
        ])
    }

    @Test("a conflict takes in every change that touches it, on either side")
    func joinedChanges() {
        // Theirs' first change touches yours, and its second, one line further on, merges.
        #expect(Self.merge("a\nb\nc\nd\n", "a\nX\nc\nd\n", "A\nb\nc\nD\n").regions == [
            Region(kind: .conflict, base: 0..<2, yours: 0..<2, theirs: 0..<2),
            Region(kind: .unchanged, base: 2..<3, yours: 2..<3, theirs: 2..<3),
            Region(kind: .theirs, base: 3..<4, yours: 3..<4, theirs: 3..<4)
        ])
        // Touching on both ends, one line joins the two changes around it.
        #expect(Self.merge("a\nb\nc\n", "a\nX\nc\n", "A\nb\nC\n").regions == [
            Region(kind: .conflict, base: 0..<3, yours: 0..<3, theirs: 0..<3)
        ])
        // Two of yours inside one of theirs.
        #expect(Self.merge("a\nb\nc\nd\ne\n", "a\nX\nc\nY\ne\n", "a\nB\nC\nD\ne\n").regions == [
            Region(kind: .unchanged, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .conflict, base: 1..<4, yours: 1..<4, theirs: 1..<4),
            Region(kind: .unchanged, base: 4..<5, yours: 4..<5, theirs: 4..<5)
        ])
        // One of theirs bridging two of yours that are three lines apart.
        let base = "a\nb\nc\nd\ne\nf\ng\n"
        #expect(Self.merge(base, "a\nX\nc\nd\ne\nY\ng\n", "a\nb\nC\nD\nE\nf\ng\n").regions == [
            Region(kind: .unchanged, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .conflict, base: 1..<6, yours: 1..<6, theirs: 1..<6),
            Region(kind: .unchanged, base: 6..<7, yours: 6..<7, theirs: 6..<7)
        ])
    }

    @Test("a conflict's shared first and last lines move out of it, and its base stays whole")
    func trimming() {
        let base = "a\nb\nc\n"
        let yours = "a\nS\nX\nT\nc\n"
        let theirs = "a\nS\nY\nT\nc\n"
        #expect(Self.merge(base, yours, theirs, trimsConflicts: false).regions == [
            Region(kind: .unchanged, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .conflict, base: 1..<2, yours: 1..<4, theirs: 1..<4),
            Region(kind: .unchanged, base: 2..<3, yours: 4..<5, theirs: 4..<5)
        ])
        #expect(Self.merge(base, yours, theirs).regions == [
            Region(kind: .unchanged, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .same, base: 1..<1, yours: 1..<2, theirs: 1..<2),
            Region(kind: .conflict, base: 1..<2, yours: 2..<3, theirs: 2..<3),
            Region(kind: .same, base: 2..<2, yours: 3..<4, theirs: 3..<4),
            Region(kind: .unchanged, base: 2..<3, yours: 4..<5, theirs: 4..<5)
        ])
    }

    @Test("trimming stops at the first line the sides do not share, even one the base has")
    func partialTrimming() {
        // git --zdiff3: a, S, `<<<<<<< O` c `||||||| B` b, c `=======` Q `>>>>>>> T`, d.
        #expect(Self.merge("a\nb\nc\nd\n", "a\nS\nc\nd\n", "a\nS\nQ\nd\n").regions == [
            Region(kind: .unchanged, base: 0..<1, yours: 0..<1, theirs: 0..<1),
            Region(kind: .same, base: 1..<1, yours: 1..<2, theirs: 1..<2),
            Region(kind: .conflict, base: 1..<3, yours: 2..<3, theirs: 2..<3),
            Region(kind: .unchanged, base: 3..<4, yours: 3..<4, theirs: 3..<4)
        ])
    }

    @Test("lines are the same only as bytes: a decomposed é against a precomposed one conflicts")
    func bytesNotCharacters() {
        let merge = Self.merge("a\nb\n", "a\ncaf\u{E9}\n", "a\ncafe\u{301}\n")
        #expect(merge.regions.map(\.kind) == [.unchanged, .conflict])
    }

    @Test("a line ending is part of the line: LF to CRLF and a dropped final break are changes")
    func lineEndings() {
        #expect(Self.merge("a\nb\nc\n", "a\r\nb\nc\n", "a\nb\nC\n").regions.map(\.kind) == [
            .yours, .unchanged, .theirs
        ])
        #expect(Self.merged("a\nb\nc\n", "a\r\nb\nc\n", "a\nb\nC\n") == "a\r\nb\nC\n")
        // Dropping the last line's break changes that line, which touches a line added after it.
        #expect(Self.merge("a\nb\n", "a\nb", "a\nb\nc\n").regions.map(\.kind) == [
            .unchanged, .conflict
        ])
        #expect(Self.merged("a\nb\nc\n", "A\nb\nc\n", "a\nb\nc") == "A\nb\nc")
    }

    @Test("a side left as the base gives the other side, and empty texts merge to nothing")
    func trivialSides() {
        #expect(Self.merged("a\nb\n", "a\nb\n", "x\ny\n") == "x\ny\n")
        #expect(Self.merged("a\nb\n", "x\n", "a\nb\n") == "x\n")
        #expect(Self.merged("", "", "")?.isEmpty == true)
        #expect(Self.merge("", "", "").regions.isEmpty)
        #expect(Self.merge("", "a\n", "b\n").regions == [
            Region(kind: .conflict, base: 0..<0, yours: 0..<1, theirs: 0..<1)
        ])
    }
}
