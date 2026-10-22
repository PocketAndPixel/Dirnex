import Foundation

/// Moving each block of changed lines to the position that reads best, without changing what
/// changed (PLAN.md §M31 Slice 2).
///
/// A block can often sit in more than one place. Inserting a function between two others, the
/// search may report `}`, a blank line and `func b() {` as new, where a reader expects
/// `func b() {` through the blank line after it: the same lines, rotated. A block may move up by one
/// whenever the line above it equals its last line, and down by one whenever the line below it
/// equals its first, and the count of changed lines stays the same either way.
///
/// The choice follows git's order, measured against git 2.54 on 2026-10-22:
/// 1. A block that can sit opposite a changed block on the other side goes there, so the two read
///    as one replacement rather than a removal and an insertion.
/// 2. Otherwise the position with the cheapest boundaries wins (`boundaryCost`): a block should
///    start and end at the start of a paragraph, at a low indent. Ties go to the lowest position,
///    which is where git puts every block when its own heuristic is off.
///
/// The scoring is Dirnex's own rather than git's indent heuristic, and it is held to git's choices
/// by test cases probed from git and by a run over this repository's history.
struct ChangeSliding {
    /// One side of the comparison: its line identities, which lines are changed, and the shape of
    /// each line for scoring.
    struct Side {
        let ids: [Int32]
        var changed: [Bool]
        let shapes: [LineShape]
    }

    /// How a line looks to the scoring: whether it is blank, and how far it is indented.
    struct LineShape {
        let isBlank: Bool
        /// Columns of leading whitespace; a tab counts as four.
        let indent: Int

        init(_ content: Substring) {
            var columns = 0
            var isBlank = true
            for byte in content.utf8 {
                if byte == UInt8(ascii: " ") {
                    columns += 1
                } else if byte == UInt8(ascii: "\t") {
                    columns += 4
                } else {
                    isBlank = false
                    break
                }
            }
            self.isBlank = isBlank
            indent = isBlank ? 0 : columns
        }
    }

    /// How far above its lowest position a block is considered, so a run of thousands of identical
    /// lines costs a bounded amount of scoring.
    static let maximumSlide = 100

    /// Slide the blocks of both sides, the left first. Each side's blocks keep the other side's in
    /// view, so the second pass sees where the first one put things.
    static func slide(_ left: inout Side, _ right: inout Side) {
        slide(&left, against: right)
        slide(&right, against: left)
    }

    private static func slide(_ side: inout Side, against other: Side) {
        let otherHasChange = changesByGap(other.changed)
        let costs = BoundaryCosts(side.shapes)
        var block = Block(start: 0, end: 0, gap: 0)
        while block.end < side.changed.count {
            guard side.changed[block.end] else {
                block.end += 1
                block.gap += 1
                continue
            }
            block.start = block.end
            while block.end < side.changed.count, side.changed[block.end] {
                block.end += 1
            }
            place(&block, in: &side, otherHasChange: otherHasChange, costs: costs)
        }
    }

    /// A run of changed lines, and its gap: how many unchanged lines come before it. Unchanged lines
    /// pair one to one across the sides, so the same gap on the other side is the place opposite.
    private struct Block {
        var start: Int
        var end: Int
        var gap: Int
    }

    /// Move one block to its chosen position, absorbing any neighbor it comes to touch.
    private static func place(
        _ block: inout Block,
        in side: inout Side,
        otherHasChange: [Bool],
        costs: BoundaryCosts
    ) {
        var length: Int
        var highestEnd: Int
        var opposite: Int?
        repeat {
            length = block.end - block.start
            while slideUp(&block, in: &side) {}
            highestEnd = block.end
            opposite = otherHasChange[block.gap] ? block.end : nil
            while slideDown(&block, in: &side) {
                if otherHasChange[block.gap] {
                    opposite = block.end
                }
            }
            // Absorbing a neighbor can open new room to slide, so go round until nothing grows.
        } while block.end - block.start != length

        var target = block.end
        if let opposite {
            target = opposite
        } else if block.end > highestEnd {
            let lowest = block.end
            var best = costs.cost(start: lowest - length, end: lowest)
            for end in stride(
                from: lowest - 1,
                through: max(highestEnd, lowest - maximumSlide),
                by: -1
            ) {
                let cost = costs.cost(start: end - length, end: end)
                if cost < best {
                    best = cost
                    target = end
                }
            }
        }
        while block.end > target, slideUp(&block, in: &side) {}
    }

    /// Move the block up by one line if the line above it equals its last line, then absorb any
    /// changed lines it now touches.
    private static func slideUp(_ block: inout Block, in side: inout Side) -> Bool {
        guard block.start > 0, side.ids[block.start - 1] == side.ids[block.end - 1] else {
            return false
        }
        side.changed[block.start - 1] = true
        side.changed[block.end - 1] = false
        block.start -= 1
        block.end -= 1
        block.gap -= 1
        while block.start > 0, side.changed[block.start - 1] {
            block.start -= 1
        }
        return true
    }

    /// Move the block down by one line if the line below it equals its first line, then absorb any
    /// changed lines it now touches.
    private static func slideDown(_ block: inout Block, in side: inout Side) -> Bool {
        guard block.end < side.changed.count, side.ids[block.start] == side.ids[block.end] else {
            return false
        }
        side.changed[block.start] = false
        side.changed[block.end] = true
        block.start += 1
        block.end += 1
        block.gap += 1
        while block.end < side.changed.count, side.changed[block.end] {
            block.end += 1
        }
        return true
    }

    /// For each gap, whether `changed` has changed lines there.
    private static func changesByGap(_ changed: [Bool]) -> [Bool] {
        var hasChange = [false]
        for isChanged in changed {
            if isChanged {
                hasChange[hasChange.count - 1] = true
            } else {
                hasChange.append(false)
            }
        }
        return hasChange
    }
}

/// What it costs to put a block boundary before each line: the lower, the more it reads like the
/// start of something.
private struct BoundaryCosts {
    private let shapes: [ChangeSliding.LineShape]
    /// The indent of the nearest non-blank line before each index, and at or after it.
    private let indentBehind: [Int]
    private let indentAhead: [Int]

    init(_ shapes: [ChangeSliding.LineShape]) {
        self.shapes = shapes
        var indentBehind = Array(repeating: 0, count: shapes.count)
        var previous = 0
        for index in shapes.indices {
            indentBehind[index] = previous
            if !shapes[index].isBlank {
                previous = shapes[index].indent
            }
        }
        var indentAhead = Array(repeating: 0, count: shapes.count)
        var next = 0
        for index in shapes.indices.reversed() {
            if !shapes[index].isBlank {
                next = shapes[index].indent
            }
            indentAhead[index] = next
        }
        self.indentBehind = indentBehind
        self.indentAhead = indentAhead
    }

    /// The cost of a block occupying `start..<end`: both of its boundaries.
    func cost(start: Int, end: Int) -> Int {
        boundaryCost(before: start) + boundaryCost(before: end)
    }

    /// A boundary is cheapest just after a blank line, just before content, and where neither the
    /// line before it nor the line after it is deeply indented: between two declarations rather
    /// than inside one. The end of the file is free.
    ///
    /// The indent is the deeper of the two sides, because a boundary with a nested line on either
    /// side cuts into a body. Inserting a method at the end of a type shows why: `}` then a blank
    /// line then the new method reads right, and the rotation that starts at the previous method's
    /// `}` and stops inside the new one's body does not. Each level of four columns costs as much
    /// as a missing paragraph break, so nesting outweighs blank lines.
    private func boundaryCost(before index: Int) -> Int {
        guard index < shapes.count else { return 0 }
        var cost = 0
        if shapes[index].isBlank {
            cost += 2
        }
        if index > 0, !shapes[index - 1].isBlank {
            cost += 2
        }
        cost += min(max(indentBehind[index], indentAhead[index]), 80) / 2
        return cost
    }
}
