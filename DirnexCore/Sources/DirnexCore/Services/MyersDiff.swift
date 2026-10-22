import Foundation

/// Which elements of two sequences fall outside a longest common subsequence: the lines a
/// comparison reports as removed from the left and inserted on the right (PLAN.md §M31).
///
/// Myers' O(ND) algorithm in its linear-space form ("An O(ND) Difference Algorithm and Its
/// Variations", 1986): search from both corners at once until the two searches meet, split the box
/// at the meeting point, and solve the two halves. The halves go on a work list rather than the call
/// stack, so a deep split cannot overflow it.
///
/// **The search has a cost limit.** Two large files with many repeated lines are the slow case, and
/// it is not rare: measured with git 2.54 on two 100 000-line files over a ten-line alphabet, an
/// unbounded search took 12.7 s where git's limit took 0.19 s. When the two searches have each
/// spent `costLimit` steps without meeting, the box is split where either got furthest, which is a
/// valid split of a path that is no longer guaranteed to be the shortest. A limit of `Int.max` is
/// git's `--minimal`.
///
/// The elements are line identities, already interned, so a comparison is one integer compare.
struct MyersDiff {
    private let left: [Int32]
    private let right: [Int32]
    private let costLimit: Int
    private(set) var leftChanged: [Bool]
    private(set) var rightChanged: [Bool]

    /// A rectangle of the edit graph still to be solved: `left[leftStart..<leftEnd]` against
    /// `right[rightStart..<rightEnd]`.
    fileprivate struct Box {
        var leftStart: Int
        var leftEnd: Int
        var rightStart: Int
        var rightEnd: Int
    }

    /// Mark every element of `left` and `right` that is not part of the common subsequence found.
    static func changes(
        _ left: [Int32],
        _ right: [Int32],
        costLimit: Int
    ) -> (left: [Bool], right: [Bool]) {
        var diff = MyersDiff(left: left, right: right, costLimit: max(1, costLimit))
        diff.solve()
        return (diff.leftChanged, diff.rightChanged)
    }

    /// The default limit for a box of this many lines: the square root of the total, never under
    /// 256. Small files are always searched to the minimum, and a large one spends time in
    /// proportion to its size rather than to its size squared.
    static func defaultCostLimit(leftCount: Int, rightCount: Int) -> Int {
        max(256, Int(Double(leftCount + rightCount).squareRoot()))
    }

    private init(left: [Int32], right: [Int32], costLimit: Int) {
        self.left = left
        self.right = right
        self.costLimit = costLimit
        leftChanged = Array(repeating: false, count: left.count)
        rightChanged = Array(repeating: false, count: right.count)
    }

    private mutating func solve() {
        var pending = [Box(leftStart: 0, leftEnd: left.count, rightStart: 0, rightEnd: right.count)]
        while var box = pending.popLast() {
            trimCommonEnds(&box)
            if box.leftStart == box.leftEnd || box.rightStart == box.rightEnd {
                markAllChanged(box)
                continue
            }
            // A split on a corner would hand back the same box forever. The search cannot produce
            // one once the common ends are trimmed, but a box that is all change is still a correct
            // answer, where a loop is not.
            guard let split = middle(of: box),
                  split.x > box.leftStart || split.y > box.rightStart,
                  split.x < box.leftEnd || split.y < box.rightEnd else {
                markAllChanged(box)
                continue
            }
            pending.append(Box(
                leftStart: split.x,
                leftEnd: box.leftEnd,
                rightStart: split.y,
                rightEnd: box.rightEnd
            ))
            pending.append(Box(
                leftStart: box.leftStart,
                leftEnd: split.x,
                rightStart: box.rightStart,
                rightEnd: split.y
            ))
        }
    }

    /// Shrink the box past the lines both sides share at its start and at its end.
    private func trimCommonEnds(_ box: inout Box) {
        while box.leftStart < box.leftEnd, box.rightStart < box.rightEnd,
              left[box.leftStart] == right[box.rightStart] {
            box.leftStart += 1
            box.rightStart += 1
        }
        while box.leftStart < box.leftEnd, box.rightStart < box.rightEnd,
              left[box.leftEnd - 1] == right[box.rightEnd - 1] {
            box.leftEnd -= 1
            box.rightEnd -= 1
        }
    }

    private mutating func markAllChanged(_ box: Box) {
        for index in box.leftStart..<box.leftEnd {
            leftChanged[index] = true
        }
        for index in box.rightStart..<box.rightEnd {
            rightChanged[index] = true
        }
    }
}

// MARK: - The middle of the path

private extension MyersDiff {
    /// A point on a shortest path through `box`, strictly inside it, or `nil` if the search ended
    /// without the two halves meeting (then the whole box is reported as changed).
    func middle(of box: Box) -> (x: Int, y: Int)? {
        let context = SearchContext(left: left, right: right, box: box)
        let fullCost = (context.leftLength + context.rightLength + 1) / 2
        let limit = min(fullCost, costLimit)
        // Which search can see the meeting: with an odd difference in length, the forward one.
        let forwardMeets = context.delta % 2 != 0
        var forward = Frontier(isForward: true, limit: limit)
        var backward = Frontier(isForward: false, limit: limit)
        for cost in 0..<limit {
            if let point = forward.advance(
                cost: cost, against: backward, in: context, checksMeeting: forwardMeets
            ) {
                return point
            }
            if let point = backward.advance(
                cost: cost, against: forward, in: context, checksMeeting: !forwardMeets
            ) {
                return point
            }
        }
        guard limit < fullCost else { return nil }
        return context.furthestPoint(forward: forward, backward: backward)
    }
}

/// What one box's search needs to know, fixed for the whole search.
private struct SearchContext {
    let left: [Int32]
    let right: [Int32]
    let box: MyersDiff.Box
    let leftLength: Int
    let rightLength: Int
    let delta: Int

    init(left: [Int32], right: [Int32], box: MyersDiff.Box) {
        self.left = left
        self.right = right
        self.box = box
        leftLength = box.leftEnd - box.leftStart
        rightLength = box.rightEnd - box.rightStart
        delta = leftLength - rightLength
    }

    /// Whether the `x`th element along a search's direction matches the `y`th.
    func matches(_ x: Int, _ y: Int, isForward: Bool) -> Bool {
        isForward
            ? left[box.leftStart + x] == right[box.rightStart + y]
            : left[box.leftEnd - 1 - x] == right[box.rightEnd - 1 - y]
    }

    /// A point measured from a search's own corner, in the box's coordinates.
    func point(x: Int, y: Int, isForward: Bool) -> (x: Int, y: Int) {
        isForward
            ? (box.leftStart + x, box.rightStart + y)
            : (box.leftEnd - x, box.rightEnd - y)
    }

    /// Where the searches stopped making a shortest path: the point either got furthest along,
    /// counted as lines consumed from its own corner.
    func furthestPoint(forward: Frontier, backward: Frontier) -> (x: Int, y: Int)? {
        let ahead = forward.furthest(in: self)
        let behind = backward.furthest(in: self)
        if let ahead, ahead.x + ahead.y >= (behind.map { $0.x + $0.y } ?? 0) {
            return point(x: ahead.x, y: ahead.y, isForward: true)
        }
        guard let behind else { return nil }
        return point(x: behind.x, y: behind.y, isForward: false)
    }
}

/// One search's furthest reach on each diagonal.
///
/// A diagonal is `x - y`, offset so the lowest one in reach sits near index 0. `-1` means not
/// reached. The backward search measures from the box's far corner, so the two read the same way.
private struct Frontier {
    let isForward: Bool
    let offset: Int
    var reach: [Int]
    /// How many diagonals at the low and the high end have run off the box and are skipped.
    var lowTrim = 0
    var highTrim = 0

    init(isForward: Bool, limit: Int) {
        self.isForward = isForward
        offset = limit + 1
        reach = Array(repeating: -1, count: 2 * limit + 3)
        // The point before the first step, so cost 0 starts at x = 0 on diagonal 0.
        reach[offset + 1] = 0
    }

    /// One step of the search: every diagonal it reaches at `cost`, each followed down its run of
    /// matching lines. Answers the meeting point once the two searches overlap.
    mutating func advance(
        cost: Int,
        against other: Frontier,
        in context: SearchContext,
        checksMeeting: Bool
    ) -> (x: Int, y: Int)? {
        var diagonal = -cost + lowTrim
        while diagonal <= cost - highTrim {
            defer { diagonal += 2 }
            let index = offset + diagonal
            // Down from the diagonal above, or across from the one below, whichever got further.
            var x = diagonal == -cost || (diagonal != cost && reach[index - 1] < reach[index + 1])
                ? reach[index + 1]
                : reach[index - 1] + 1
            var y = x - diagonal
            while x < context.leftLength, y < context.rightLength,
                  context.matches(x, y, isForward: isForward) {
                x += 1
                y += 1
            }
            reach[index] = x
            if x > context.leftLength {
                highTrim += 2
                continue
            }
            if y > context.rightLength {
                lowTrim += 2
                continue
            }
            guard checksMeeting else { continue }
            let mirrored = offset + context.delta - diagonal
            guard other.reach.indices.contains(mirrored), other.reach[mirrored] != -1,
                  x + other.reach[mirrored] >= context.leftLength else { continue }
            if isForward {
                return context.point(x: x, y: y, isForward: true)
            }
            // Report the forward search's end of the overlap, which is a point on its path.
            let forwardX = other.reach[mirrored]
            return context.point(x: forwardX, y: forwardX - (mirrored - offset), isForward: true)
        }
        return nil
    }

    /// The reached point that has consumed the most lines, if any lies inside the box.
    func furthest(in context: SearchContext) -> (x: Int, y: Int)? {
        var best: (x: Int, y: Int)?
        for (index, x) in reach.enumerated() where x >= 0 {
            let y = x - (index - offset)
            guard x <= context.leftLength, y >= 0, y <= context.rightLength,
                  x + y > (best.map { $0.x + $0.y } ?? 0) else { continue }
            best = (x, y)
        }
        return best
    }
}
