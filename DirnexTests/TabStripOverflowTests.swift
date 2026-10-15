import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// A strip too narrow for every chip at a readable width: a run of them holding the showing tab, a »
/// listing the rest, and a strip that never asks its pane for more room.
///
/// Before the » the chips shrank to their glyph and ×, and past that the strip's required minimum
/// width pushed the split divider into the other pane (seen live with thirteen tabs, 80 pt).
@MainActor
@Suite("Tabs that don't fit go to the » menu", .serialized)
struct TabStripOverflowTests {
    private let nine = TabStripFixture.folders(TabStripFixture.titles)

    /// The chips on the strip, in order, with nothing overlapping: each chip ends before the next
    /// begins, the » follows the last, and the new-tab button follows the », inside the strip.
    private func expectTidy(_ strip: TabStripFixture) {
        let bar = strip.bar
        let frames = bar.chips[bar.visibleRange].map(strip.frame(of:))
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(left.maxX <= right.minX + 0.5, "\(left) runs into \(right)")
        }
        var edge = frames.last?.maxX ?? 0
        if !bar.overflowButton.isHidden {
            #expect(edge <= bar.overflowButton.frame.minX + 0.5)
            edge = bar.overflowButton.frame.maxX
        }
        #expect(edge <= bar.newButton.frame.minX + 0.5)
        #expect(bar.newButton.frame.maxX <= bar.bounds.width + 0.5)
        for chip in bar.chips {
            #expect(chip.isHidden == !bar.visibleRange.contains(chip.index), "\(chip.title)")
        }
    }

    @Test("past the readable floor, the tabs after the run go behind a » and the rest stay readable")
    func overflowKeepsLabelsReadable() {
        let strip = TabStripFixture(nine, width: 600)
        let bar = strip.bar
        #expect(bar.visibleRange.lowerBound == 0)
        #expect(bar.visibleRange.count < 9)
        #expect(!bar.overflowButton.isHidden)
        #expect(abs(bar.frame.width - 600) < 0.5, "the strip widened its window")
        expectTidy(strip)
        strip.expectReadableLabels()
    }

    /// Found live with eighteen tabs: Documents was cut to "Doc…", under the floor, beside a whole
    /// Downloads. Hidden chips stay in the view tree, and while they were still held under the
    /// shared cap, long titles among them made lowering the cap cost more than squeezing one chip.
    @Test("the chips on an overfull strip share its squeeze fairly, whatever is hidden")
    func runSharesTheSqueeze() {
        let titles = [
            "Movies", "new", "Library", "Downloads", "Documents", "Applications",
            "Screenshots 2026",
            "Library", "Desktop", "Pictures", "Movies", "x", "Movies", "Pictures", "Desktop",
            "Library",
            "Documents", "Downloads"
        ]
        let items = TabStripFixture.folders(titles)
        let natural = TabStripFixture(items, width: 3000).bar.chips.map(\.frame.width)
        let strip = TabStripFixture(items, width: 600, active: 17)
        let bar = strip.bar
        let shown = bar.chips[bar.visibleRange]
        let cap = shown.map(\.frame.width).max() ?? 0
        for chip in shown {
            let fair = min(natural[chip.index], cap)
            #expect(
                abs(chip.frame.width - fair) <= 1,
                "\(chip.title): \(chip.frame.width) where \(fair) is fair"
            )
        }
        strip.expectReadableLabels()
    }

    @Test("widening the strip brings the hidden tabs back, and the » goes")
    func resizeBringsTabsBack() {
        let strip = TabStripFixture(nine, width: 600)
        strip.window.setContentSize(NSSize(width: 900, height: 40))
        strip.window.layoutIfNeeded()
        #expect(strip.bar.visibleRange == 0..<9)
        #expect(strip.bar.overflowButton.isHidden)
        expectTidy(strip)

        strip.window.setContentSize(NSSize(width: 600, height: 40))
        strip.window.layoutIfNeeded()
        #expect(strip.bar.visibleRange.count < 9)
        expectTidy(strip)
    }

    @Test("the showing tab always has a chip, and switching along the run leaves it where it is")
    func activeStaysOnTheStrip() {
        let strip = TabStripFixture(nine, width: 600, active: 8)
        let run = strip.bar.visibleRange
        #expect(run.upperBound == 9)
        #expect(run.lowerBound > 0)
        expectTidy(strip)

        strip.show(nine, active: run.lowerBound)
        #expect(strip.bar.visibleRange == run)
        strip.show(nine, active: 0)
        #expect(strip.bar.visibleRange.lowerBound == 0)
        #expect(!strip.bar.chips[0].isHidden)
    }

    @Test(
        "the » lists the hidden tabs in strip order, split around the run, and selects the one chosen"
    )
    func menuListsAndSelects() throws {
        let strip = TabStripFixture(nine, width: 400, active: 4)
        let bar = strip.bar
        let recorder = SelectionRecorder()
        bar.delegate = recorder
        let run = bar.visibleRange
        try #require(
            run.lowerBound > 0 && run.upperBound < 9,
            "want hidden tabs on both sides of \(run)"
        )

        let items = bar.overflowMenu().items
        let titles = items.map { $0.isSeparatorItem ? "—" : $0.title }
        let hidden = TabStripFixture.titles
        #expect(
            titles == Array(hidden[..<run.lowerBound]) + ["—"] + Array(hidden[run.upperBound...])
        )
        for item in items where !item.isSeparatorItem {
            #expect(item.image != nil, "\(item.title)")
        }

        let last = try #require(items.last)
        #expect(NSApp.sendAction(try #require(last.action), to: last.target, from: last))
        #expect(recorder.selected == [8])
    }

    @Test("a drop on an overfull strip names the gap in the whole list, not among the chips shown")
    func dropSlotsCountHiddenTabs() {
        let strip = TabStripFixture(nine, width: 600, active: 8)
        let bar = strip.bar
        let run = bar.visibleRange
        let first = strip.frame(of: bar.chips[run.lowerBound])
        let last = strip.frame(of: bar.chips[run.upperBound - 1])
        #expect(bar.dropSlot(atX: first.minX + 2) == run.lowerBound)
        #expect(bar.dropSlot(atX: last.maxX - 2) == run.upperBound)
        #expect(bar.dropSlot(atX: last.minX + 2) == run.upperBound - 1)
    }

    /// The bug the » removes at its root: thirteen tabs needed more than the pane had, the strip's
    /// stack resisted clipping at required, and the pane grew, which in the browser moves the divider.
    @Test("thirteen tabs leave the pane's width alone")
    func paneIsNotWidened() async throws {
        let windowed = windowedPane(at: .local("/tmp"))
        let pane = windowed.pane
        try await settleUntil { pane.tabs[0].hasLoaded }
        let width = windowed.window.frame.width
        for index in 1..<13 {
            pane.tabs.append(PanelTab(path: .local("/tmp/dirnex-tab-overflow-\(index)")))
        }
        pane.refreshTabBar()
        windowed.window.layoutIfNeeded()

        #expect(windowed.window.frame.width == width)
        #expect(pane.tabBar.frame.maxX <= pane.view.bounds.width)
        #expect(!pane.tabBar.overflowButton.isHidden)
        #expect(pane.tabBar.visibleRange.contains(pane.activeTabIndex))
    }
}

/// A strip's owner that only records which tabs it was asked to show.
@MainActor
private final class SelectionRecorder: TabBarViewDelegate {
    var selected: [Int] = []

    func tabBar(_ bar: TabBarView, didSelectTabAt index: Int) {
        selected.append(index)
    }

    func tabBar(_ bar: TabBarView, didCloseTabAt index: Int) {}
    func tabBar(_ bar: TabBarView, didMoveTabFrom source: Int, toSlot slot: Int) {}
    func tabBar(
        _ bar: TabBarView,
        didReceiveTabAt index: Int,
        from source: TabBarView,
        atSlot slot: Int
    ) {}
    func tabBar(_ bar: TabBarView, didRequestOtherPanelForTabAt index: Int) {}
    func tabBar(_ bar: TabBarView, tabDragIsInFlight inFlight: Bool) {}
    func tabBarDidRequestNewTab(_ bar: TabBarView) {}
}
