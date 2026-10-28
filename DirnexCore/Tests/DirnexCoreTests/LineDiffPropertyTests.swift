import Foundation
import Testing

@testable import DirnexCore

/// `MyersDiff` and `LineDiff` against the textbook answer (PLAN.md §M31).
///
/// The oracle is the quadratic longest-common-subsequence table: slow, obviously right, and sharing
/// no code or idea with Myers' search. Two things are checked on every random pair. The result has
/// to be **valid**, meaning the unchanged elements on the two sides pair up in order and match. And
/// unless the search was cut short, it has to be **minimal**: removed plus inserted equals
/// `n + m − 2·LCS`.
@Suite("LineDiff against an LCS table")
struct LineDiffPropertyTests {
    /// The length of a longest common subsequence, one row of the table at a time.
    static func lcsLength(_ left: [Int32], _ right: [Int32]) -> Int {
        var previous = Array(repeating: 0, count: right.count + 1)
        for leftElement in left {
            var current = Array(repeating: 0, count: right.count + 1)
            for (index, rightElement) in right.enumerated() {
                current[index + 1] = leftElement == rightElement
                    ? previous[index] + 1
                    : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[right.count]
    }

    /// Whether the unchanged elements of the two sides, read in order, are the same sequence.
    static func isValid(
        _ left: [Int32],
        _ right: [Int32],
        _ changed: (left: [Bool], right: [Bool])
    ) -> Bool {
        let keptLeft = left.indices.filter { !changed.left[$0] }.map { left[$0] }
        let keptRight = right.indices.filter { !changed.right[$0] }.map { right[$0] }
        return keptLeft == keptRight
    }

    private static func randomSequence(
        maxLength: Int,
        alphabet: Int32,
        using rng: inout SeededGenerator
    ) -> [Int32] {
        (0..<Int.random(in: 0...maxLength, using: &rng)).map { _ in
            Int32.random(in: 0..<alphabet, using: &rng)
        }
    }

    @Test("an unlimited search is valid and minimal on 3 000 random pairs")
    func minimalOnRandomPairs() {
        var rng = SeededGenerator(seed: 0x0031_0001)
        for _ in 0..<3000 {
            let alphabet = Int32.random(in: 1...6, using: &rng)
            let left = Self.randomSequence(maxLength: 30, alphabet: alphabet, using: &rng)
            let right = Self.randomSequence(maxLength: 30, alphabet: alphabet, using: &rng)
            let changed = MyersDiff.changes(left, right, costLimit: .max)
            let edits = changed.left.count(where: \.self) + changed.right.count(where: \.self)
            let minimum = left.count + right.count - 2 * Self.lcsLength(left, right)
            #expect(Self.isValid(left, right, changed), "\(left) → \(right)")
            #expect(edits == minimum, "\(left) → \(right)")
        }
    }

    @Test("a search cut short by its cost limit is still valid, and the limit really engages")
    func limitedSearchIsValid() {
        var rng = SeededGenerator(seed: 0x0031_0002)
        var cutShort = 0
        for costLimit in 1...4 {
            for _ in 0..<500 {
                let left = Self.randomSequence(maxLength: 60, alphabet: 4, using: &rng)
                let right = Self.randomSequence(maxLength: 60, alphabet: 4, using: &rng)
                let changed = MyersDiff.changes(left, right, costLimit: costLimit)
                let edits = changed.left.count(where: \.self) + changed.right.count(where: \.self)
                let minimum = left.count + right.count - 2 * Self.lcsLength(left, right)
                #expect(Self.isValid(left, right, changed), "limit \(costLimit): \(left) → \(right)")
                #expect(edits >= minimum)
                if edits > minimum {
                    cutShort += 1
                }
            }
        }
        // Without this, a limit that never engaged would pass the loop above on minimal answers
        // alone, and the furthest-point split would have gone untested.
        #expect(cutShort > 100)
    }

    @Test("setting aside lines found on one side only does not change the answer")
    func oneSidedLinesAreSetAside() {
        var rng = SeededGenerator(seed: 0x0031_0003)
        var unique = 0
        func text(_ ids: [Int32]) -> [String] {
            ids.map { id in
                // About one line in four is unique to its side; the rest repeat across both.
                guard Int.random(in: 0..<4, using: &rng) == 0 else { return "line \(id)" }
                unique += 1
                return "unique \(unique)"
            }
        }
        for _ in 0..<1000 {
            let left = text(Self.randomSequence(maxLength: 40, alphabet: 5, using: &rng))
            let right = text(Self.randomSequence(maxLength: 40, alphabet: 5, using: &rng))
            let diff = LineDiff.compare(
                left.map { $0 + "\n" }.joined(),
                right.map { $0 + "\n" }.joined(),
                options: LineDiffOptions(isMinimal: true)
            )
            let interned = Self.intern(left, right)
            let minimum = left.count + right.count
                - 2 * Self.lcsLength(interned.left, interned.right)
            #expect(diff.removedLineCount + diff.insertedLineCount == minimum)
            #expect(Self.unchangedLinesMatch(left, right, diff))
            let noEmptyBlock = diff.changes.allSatisfy { !$0.left.isEmpty || !$0.right.isEmpty }
            #expect(noEmptyBlock)
        }
    }

    /// The same strings as the same integers, for the LCS table.
    private static func intern(_ left: [String], _ right: [String]) -> (
        left: [Int32],
        right: [Int32]
    ) {
        var table: [String: Int32] = [:]
        func id(_ line: String) -> Int32 {
            if let known = table[line] {
                return known
            }
            table[line] = Int32(table.count)
            return Int32(table.count - 1)
        }
        return (left.map(id), right.map(id))
    }

    /// The lines outside every change, read in order on each side, are the same lines; and the
    /// blocks are in order, apart, and inside the texts.
    private static func unchangedLinesMatch(_ left: [String], _ right: [String], _ diff: LineDiff) -> Bool {
        var leftKept = Array(repeating: true, count: left.count)
        var rightKept = Array(repeating: true, count: right.count)
        var previous: LineDiff.Change?
        for change in diff.changes {
            // Each block starts after the previous one ends, with an unchanged line between them
            // on both sides: that line is what separates two blocks.
            if let previous, change.left.lowerBound <= previous.left.upperBound
                || change.right.lowerBound <= previous.right.upperBound {
                return false
            }
            guard change.left.upperBound <= left.count,
                  change.right.upperBound <= right.count else { return false }
            change.left.forEach { leftKept[$0] = false }
            change.right.forEach { rightKept[$0] = false }
            previous = change
        }
        let keptLeft = left.indices.filter { leftKept[$0] }.map { left[$0] }
        let keptRight = right.indices.filter { rightKept[$0] }.map { right[$0] }
        return keptLeft == keptRight
    }
}
