import Foundation
import Testing

@testable import DirnexCore

/// The two panes' strips read as one ring: a tab stepped off one strip's end goes on into the other
/// pane, and so does a step of the view. Apart from `TabListTests`, which is about one strip.
@Suite("TabList across both panes")
struct TabListRingTests {
    /// Four tabs, A to D, showing the one at `active`.
    private func list(active: Int = 0) -> TabList<String> {
        TabList(tabs: ["A", "B", "C", "D"], activeIndex: active)
    }

    // MARK: - A step that may cross into the other pane

    @Test("a step with a neighbour on that side stays on the strip, whatever the other pane holds")
    func stepPrefersTheStrip() {
        #expect(list(active: 1).step(by: 1, otherPaneTabCount: 3) == .along)
        #expect(list(active: 1).step(by: -1, otherPaneTabCount: 3) == .along)
        #expect(list(active: 1).step(by: 1, otherPaneTabCount: nil) == .along)
    }

    /// Past a strip's right end is the other pane's start, and past its left end the other pane's end,
    /// so `count` names the gap after the other pane's last tab. The same from either pane.
    @Test("off the end of the strip a tab enters the other pane at the end it is heading for")
    func stepCrossesAtTheNearEnd() {
        #expect(list(active: 3).step(by: 1, otherPaneTabCount: 2) == .across(slot: 0))
        #expect(list(active: 0).step(by: -1, otherPaneTabCount: 2) == .across(slot: 2))
    }

    @Test("with no other pane a step off the end goes nowhere")
    func stepStopsAtTheOuterEnds() {
        #expect(list(active: 3).step(by: 1, otherPaneTabCount: nil) == .stays)
        #expect(list(active: 0).step(by: -1, otherPaneTabCount: nil) == .stays)
    }

    @Test("a pane's last tab stays, and so does a step of nothing")
    func stepKeepsTheLastTab() {
        let lone = TabList(tabs: ["A"], activeIndex: 0)
        #expect(lone.step(by: 1, otherPaneTabCount: 2) == .stays)
        #expect(lone.step(by: -1, otherPaneTabCount: 2) == .stays)
        #expect(list(active: 0).step(by: 0, otherPaneTabCount: 2) == .stays)
    }

    /// The promise in the doc comment: the opposite step undoes a crossing, carried out here the way
    /// the app does, by taking the tab out of one list and inserting it into the other.
    @Test("a crossing and the opposite step put both lists back")
    func stepAcrossAndBack() throws {
        var left = TabList(tabs: ["A", "B", "C"], activeIndex: 2)
        var right = TabList(tabs: ["X", "Y"], activeIndex: 1)
        let before = (left, right)

        guard case let .across(slot) = left.step(by: 1, otherPaneTabCount: right.tabs.count) else {
            Issue.record("expected a crossing to the right")
            return
        }
        let leaving = left.remove(at: left.activeIndex)
        right.insert(try #require(leaving), atSlot: slot)
        #expect(right.tabs == ["C", "X", "Y"])
        #expect(right.activeIndex == 0)

        guard case let .across(back) = right.step(by: -1, otherPaneTabCount: left.tabs.count) else {
            Issue.record("expected a crossing back to the left")
            return
        }
        let returning = right.remove(at: right.activeIndex)
        left.insert(try #require(returning), atSlot: back)
        #expect(left == before.0)
        #expect(right.tabs == before.1.tabs)
    }

    /// Carried out the way the app does: a crossing takes the tab out of one list and into the other,
    /// and the pane it lands in is the one asked for the next step. Each state reads left|right.
    @Test("a tab stepped the same way goes round both panes and comes back, in either direction")
    func stepRoundTheRing() throws {
        let rounds = [
            (1, ["AB|CXY", "AB|XCY", "AB|XYC", "CAB|XY", "ACB|XY", "ABC|XY"]),
            (-1, ["ACB|XY", "CAB|XY", "AB|XYC", "AB|XCY", "AB|CXY", "ABC|XY"])
        ]
        for (offset, expected) in rounds {
            var panes = [
                TabList(tabs: ["A", "B", "C"], activeIndex: 2),
                TabList(tabs: ["X", "Y"], activeIndex: 1)
            ]
            var focused = 0
            var seen: [String] = []
            for _ in expected {
                let other = 1 - focused
                switch panes[focused].step(by: offset, otherPaneTabCount: panes[other].tabs.count) {
                case .along:
                    panes[focused].moveActive(by: offset)
                case let .across(slot):
                    let index = panes[focused].activeIndex
                    let leaving = panes[focused].remove(at: index)
                    panes[other].insert(try #require(leaving), atSlot: slot)
                    focused = other
                case .stays:
                    Issue.record("a step went nowhere")
                }
                seen.append(panes[0].tabs.joined() + "|" + panes[1].tabs.joined())
            }
            #expect(seen == expected, "by \(offset)")
        }
    }

    // MARK: - Showing another tab

    @Test("the view steps along the strip while there is a tab that way")
    func showAlongTheStrip() {
        #expect(list(active: 1).tabToShow(by: 1, otherPaneTabCount: 3) == .here(index: 2))
        #expect(list(active: 1).tabToShow(by: -1, otherPaneTabCount: 3) == .here(index: 0))
    }

    @Test("past the strip's right end is the other pane's first tab, past its left end its last")
    func showAcrossAtTheNearEnd() {
        #expect(list(active: 3).tabToShow(by: 1, otherPaneTabCount: 2) == .otherPane(index: 0))
        #expect(list(active: 0).tabToShow(by: -1, otherPaneTabCount: 2) == .otherPane(index: 1))
    }

    @Test("with no other pane the view goes round its own strip")
    func showRoundOneStrip() {
        #expect(list(active: 3).tabToShow(by: 1, otherPaneTabCount: 0) == .here(index: 0))
        #expect(list(active: 0).tabToShow(by: -1, otherPaneTabCount: 0) == .here(index: 3))
    }

    @Test("a pane's lone tab steps to the other pane's, and the only tab there is stays")
    func showFromALoneTab() {
        let lone = TabList(tabs: ["A"], activeIndex: 0)
        #expect(lone.tabToShow(by: 1, otherPaneTabCount: 1) == .otherPane(index: 0))
        #expect(lone.tabToShow(by: -1, otherPaneTabCount: 1) == .otherPane(index: 0))
        #expect(lone.tabToShow(by: 1, otherPaneTabCount: 0) == .current)
        #expect(list(active: 1).tabToShow(by: 0, otherPaneTabCount: 2) == .current)
    }

    /// Carried out the way the app does: the pane a step lands in is the one asked for the next.
    @Test("stepping the same way round both panes shows every tab once, in either direction")
    func showRoundTheRing() {
        for (offset, expected) in [(1, ["B", "C", "X", "Y", "A"]), (-1, ["Y", "X", "C", "B", "A"])] {
            var panes = [
                TabList(tabs: ["A", "B", "C"], activeIndex: 0),
                TabList(tabs: ["X", "Y"], activeIndex: 0)
            ]
            var focused = 0
            var shown: [String] = []
            for _ in expected {
                let other = 1 - focused
                switch panes[focused].tabToShow(
                    by: offset,
                    otherPaneTabCount: panes[other].tabs.count
                ) {
                case let .here(index):
                    panes[focused] = TabList(tabs: panes[focused].tabs, activeIndex: index)
                case let .otherPane(index):
                    panes[other] = TabList(tabs: panes[other].tabs, activeIndex: index)
                    focused = other
                case .current:
                    Issue.record("a step stayed on its tab")
                }
                shown.append(panes[focused].tabs[panes[focused].activeIndex])
            }
            #expect(shown == expected, "by \(offset)")
        }
    }
}
