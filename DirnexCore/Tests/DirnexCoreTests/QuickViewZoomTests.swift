import Testing

@testable import DirnexCore

/// The ladder ⌘+ and ⌘− step a Quick View preview along.
@Suite("Quick View zoom")
struct QuickViewZoomTests {
    @Test("the ladder is ascending, and the starting point is on it")
    func ladderShape() {
        #expect(QuickViewZoom.levels == QuickViewZoom.levels.sorted())
        #expect(Set(QuickViewZoom.levels).count == QuickViewZoom.levels.count)
        #expect(QuickViewZoom.levels.contains(1))
    }

    @Test("stepping from the starting point goes one level either way")
    func stepsFromOne() {
        #expect(QuickViewZoom.step(from: 1, .larger) == 1.1)
        #expect(QuickViewZoom.step(from: 1, .smaller) == 0.9)
    }

    @Test("stepping away and back returns exactly to the starting point")
    func roundTrip() throws {
        var level = 1.0
        for _ in 0..<4 {
            level = try #require(QuickViewZoom.step(from: level, .larger))
        }
        #expect(level == 1.75)
        for _ in 0..<4 {
            level = try #require(QuickViewZoom.step(from: level, .smaller))
        }
        #expect(level == 1)
    }

    @Test("there is no step past either end")
    func ends() {
        #expect(QuickViewZoom.step(from: 5, .larger) == nil)
        #expect(QuickViewZoom.step(from: 0.25, .smaller) == nil)
        #expect(QuickViewZoom.step(from: 7, .larger) == nil)
        #expect(QuickViewZoom.step(from: 0.1, .smaller) == nil)
        // Past the end one way is still inside it the other way.
        #expect(QuickViewZoom.step(from: 7, .smaller) == 5)
    }

    @Test("a level left off the ladder by a pinch steps to the next one past it, not back")
    func offLadder() {
        #expect(QuickViewZoom.step(from: 1.3, .larger) == 1.5)
        #expect(QuickViewZoom.step(from: 1.3, .smaller) == 1.25)
    }

    @Test("a view's own rounding of a level does not count as being short of it")
    func rounding() {
        // A scale read back as 1.2499 or 1.2501 is 1.25: the next step up is 1.5, down is 1.1.
        #expect(QuickViewZoom.step(from: 1.2499, .larger) == 1.5)
        #expect(QuickViewZoom.step(from: 1.2501, .smaller) == 1.1)
    }
}
