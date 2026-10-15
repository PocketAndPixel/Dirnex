import Foundation
import Testing

@testable import DirnexCore

/// Which tabs keep a chip on an overfull strip.
///
/// Every strip here is ten 100-wide chips with gaps of 10 and an overflow control 30 wide, so a run
/// of n chips needs 110·n − 10, and with the control beside it 110·n + 30.
@Suite("TabOverflow")
struct TabOverflowTests {
    private func strip(width: Double, widths: [Double] = Array(repeating: 100, count: 10)) -> TabOverflow.Strip {
        TabOverflow.Strip(minimumWidths: widths, spacing: 10, width: width, overflowControlWidth: 30)
    }

    private func run(width: Double, active: Int, from previous: Int = 0) -> Range<Int> {
        TabOverflow.visibleRange(
            in: strip(width: width),
            activeIndex: active,
            previousStart: previous
        )
    }

    @Test("every tab gets a chip when they all fit, and the control takes no room")
    func allFit() {
        #expect(run(width: 1090, active: 9) == 0..<10)
        #expect(run(width: 1089, active: 0) == 0..<9)
    }

    @Test("an overfull strip shows the run from the start while the showing tab is in it")
    func leadingRun() {
        // Four chips and the control need 470.
        #expect(run(width: 470, active: 0) == 0..<4)
        // Three fit at 469: the run holding tab 2 stays at the start, and tab 3 slides it along one.
        #expect(run(width: 469, active: 2) == 0..<3)
        #expect(run(width: 469, active: 3) == 1..<4)
    }

    @Test("a showing tab past the run's end becomes its last chip")
    func slidesRight() {
        #expect(run(width: 470, active: 6) == 3..<7)
        #expect(run(width: 470, active: 9) == 6..<10)
    }

    @Test("a showing tab before the run's start becomes its first chip")
    func slidesLeft() {
        #expect(run(width: 470, active: 2, from: 5) == 2..<6)
        #expect(run(width: 470, active: 0, from: 6) == 0..<4)
    }

    @Test("switching between tabs already on the strip leaves the run where it is")
    func staysPut() {
        for active in 3..<7 {
            #expect(run(width: 470, active: active, from: 3) == 3..<7, "\(active)")
        }
    }

    @Test("a run that reaches the last tab takes earlier tabs back rather than leave room empty")
    func fillsBackFromTheEnd() {
        // Tabs closed since: a run that started at 8 of ten now has only 8 and 9 after it.
        #expect(run(width: 470, active: 9, from: 8) == 6..<10)
    }

    @Test(
        "a run that did not move keeps its first chip even when an earlier, narrower one would fit"
    )
    func noGrowthAtTheFront() {
        let widths: [Double] = [20, 100, 100, 100, 100, 100]
        let strip = strip(width: 500, widths: widths)
        // 460 of room. From 1, four 100-wide chips take 430, and the 20-wide tab 0 would fit beside
        // them (460), but adding it would shift every chip on the strip.
        #expect(TabOverflow.visibleRange(in: strip, activeIndex: 2, previousStart: 1) == 1..<5)
    }

    @Test("chips of different widths fit by their own widths")
    func unevenWidths() {
        let widths: [Double] = [40, 200, 40, 40, 40, 200]
        let strip = strip(width: 280, widths: widths)
        // 240 of room. Tabs 0 and 1 need 250 together, so tab 0 is alone on the strip.
        #expect(TabOverflow.visibleRange(in: strip, activeIndex: 0, previousStart: 0) == 0..<1)
        // Showing tab 3: the run slides to end there, stops against wide tab 1, and gives the room
        // left to tab 4 rather than leave it empty. Tab 5 is wide again and stays off.
        #expect(TabOverflow.visibleRange(in: strip, activeIndex: 3, previousStart: 0) == 2..<5)
    }

    @Test("the showing tab keeps its chip even when it alone does not fit")
    func activeAlwaysShows() {
        #expect(run(width: 50, active: 4) == 4..<5)
        #expect(run(width: 50, active: 4, from: 7) == 4..<5)
    }

    @Test("out-of-range input is clamped rather than trusted")
    func clamps() {
        #expect(run(width: 470, active: 42, from: 99) == 6..<10)
        #expect(run(width: 470, active: -3, from: -3) == 0..<4)
        let empty = TabOverflow.Strip(
            minimumWidths: [],
            spacing: 10,
            width: 100,
            overflowControlWidth: 30
        )
        #expect(TabOverflow.visibleRange(in: empty, activeIndex: 0, previousStart: 0) == 0..<0)
    }
}
