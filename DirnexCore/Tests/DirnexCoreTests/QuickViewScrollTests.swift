import Testing

@testable import DirnexCore

/// How far ⇧↑ / ⇧↓, ⇧Page Up / ⇧Page Down and ⇧← / ⇧→ move a Quick View preview.
@Suite("Quick View scroll")
struct QuickViewScrollTests {
    @Test("a line step is the same 40 points whatever the view's height")
    func lineSteps() {
        for height in [0.0, 100, 600, 2000] {
            #expect(QuickViewScroll.lineDown.travel(visibleHeight: height) == .by(40))
            #expect(QuickViewScroll.lineUp.travel(visibleHeight: height) == .by(-40))
        }
    }

    @Test("a page step keeps the last line read on screen")
    func pageStepOverlapsByALine() {
        #expect(QuickViewScroll.pageDown.travel(visibleHeight: 600) == .by(560))
        #expect(QuickViewScroll.pageUp.travel(visibleHeight: 600) == .by(-560))
    }

    /// Without the floor, a 60-point view would page by 20 points, half a line step.
    @Test("a page step on a short view is never less than half of it")
    func pageStepFloor() {
        #expect(QuickViewScroll.pageStep(visibleHeight: 60) == 30)
        #expect(QuickViewScroll.pageStep(visibleHeight: 80) == 40)
        // Where the two rules meet, and past it the overlap rule wins.
        #expect(QuickViewScroll.pageStep(visibleHeight: 81) == 41)
        #expect(QuickViewScroll.pageStep(visibleHeight: 0) == 0)
    }

    @Test("top and end go to the ends, whatever the view's height")
    func ends() {
        #expect(QuickViewScroll.top.travel(visibleHeight: 600) == .toStart)
        #expect(QuickViewScroll.end.travel(visibleHeight: 600) == .toEnd)
    }

    @Test("every move but the two ends goes by a distance, each direction its own sign")
    func signs() {
        for move in QuickViewScroll.allCases {
            switch move.travel(visibleHeight: 600) {
            case let .by(distance):
                #expect([.lineDown, .pageDown].contains(move) == (distance > 0))
            case .toStart:
                #expect(move == .top)
            case .toEnd:
                #expect(move == .end)
            }
        }
    }
}
