import Foundation
import Testing

@testable import DirnexCore

/// `#expect` cannot wrap a mutating call, so each test binds the result of one first.
@Suite("TabList")
struct TabListTests {
    /// Four tabs, A to D, showing the one at `active`.
    private func list(active: Int = 0) -> TabList<String> {
        TabList(tabs: ["A", "B", "C", "D"], activeIndex: active)
    }

    // MARK: - Slots

    @Test("a drop names the gap before the first chip whose middle is right of the pointer")
    func slotFromPointer() {
        let midpoints: [Double] = [50, 150, 250, 350]
        #expect(TabSlot.slot(forDropAt: 10, chipMidpoints: midpoints) == 0)
        #expect(TabSlot.slot(forDropAt: 120, chipMidpoints: midpoints) == 1)
        #expect(TabSlot.slot(forDropAt: 340, chipMidpoints: midpoints) == 3)
        #expect(TabSlot.slot(forDropAt: 900, chipMidpoints: midpoints) == 4)
        // Exactly on a middle is that chip's right half.
        #expect(TabSlot.slot(forDropAt: 150, chipMidpoints: midpoints) == 2)
        #expect(TabSlot.slot(forDropAt: 0, chipMidpoints: []) == 0)
    }

    @Test("the gaps on either side of a tab both leave it where it is")
    func noOpSlots() {
        #expect(TabSlot.isNoOpMove(from: 1, toSlot: 1))
        #expect(TabSlot.isNoOpMove(from: 1, toSlot: 2))
        #expect(!TabSlot.isNoOpMove(from: 1, toSlot: 0))
        #expect(!TabSlot.isNoOpMove(from: 1, toSlot: 3))
    }

    // MARK: - Moving to a slot

    /// The bug the first tab strip shipped: it read the slot as the final index, so A landed after D.
    @Test("a tab dropped in the gap before D lands before D")
    func dragRightLandsAtThePointer() {
        var tabs = list()
        let moved = tabs.move(from: 0, toSlot: 3)
        #expect(moved)
        #expect(tabs.tabs == ["B", "C", "A", "D"])
    }

    @Test("a nudge right that stays left of the next chip's middle moves nothing")
    func nudgeIsNoOp() {
        var tabs = list()
        // B dragged right but released short of C's middle: the slot is the one just after B.
        let moved = tabs.move(from: 1, toSlot: 2)
        #expect(!moved)
        #expect(tabs == list())
    }

    @Test("dragging left lands in the gap, and the end slot is after the last tab")
    func leftAndToTheEnd() {
        var left = list()
        let movedLeft = left.move(from: 3, toSlot: 1)
        #expect(movedLeft)
        #expect(left.tabs == ["A", "D", "B", "C"])

        var end = list()
        let movedToEnd = end.move(from: 0, toSlot: 4)
        #expect(movedToEnd)
        #expect(end.tabs == ["B", "C", "D", "A"])
    }

    @Test("the same tab stays showing whichever tab moves, and from either side")
    func activeTabFollowsIdentity() {
        // The showing tab itself moves.
        var moved = list(active: 0)
        moved.move(from: 0, toSlot: 3)
        #expect(moved.tabs[moved.activeIndex] == "A")

        // A tab from its left jumps over it.
        var fromLeft = list(active: 2)
        fromLeft.move(from: 0, toSlot: 4)
        #expect(fromLeft.tabs[fromLeft.activeIndex] == "C")

        // A tab from its right jumps over it.
        var fromRight = list(active: 1)
        fromRight.move(from: 3, toSlot: 0)
        #expect(fromRight.tabs == ["D", "A", "B", "C"])
        #expect(fromRight.tabs[fromRight.activeIndex] == "B")

        // A move entirely to one side of it leaves its index alone.
        var aside = list(active: 0)
        aside.move(from: 3, toSlot: 2)
        #expect(aside.activeIndex == 0)
    }

    @Test("a source or slot outside the list changes nothing")
    func outOfRange() {
        var tabs = list(active: 1)
        let attempts = [
            tabs.move(from: 4, toSlot: 0),
            tabs.move(from: -1, toSlot: 0),
            tabs.move(from: 0, toSlot: 5),
            tabs.move(from: 0, toSlot: -1)
        ]
        #expect(attempts == [false, false, false, false])
        #expect(tabs == list(active: 1))
    }

    // MARK: - Moving the showing tab by one

    @Test("the showing tab steps left and right and stays showing")
    func stepActive() {
        var tabs = list(active: 1)
        let right = tabs.moveActive(by: 1)
        #expect(right)
        #expect(tabs.tabs == ["A", "C", "B", "D"])
        #expect(tabs.activeIndex == 2)

        let lefts = [tabs.moveActive(by: -1), tabs.moveActive(by: -1)]
        #expect(lefts == [true, true])
        #expect(tabs.tabs == ["B", "A", "C", "D"])
        #expect(tabs.activeIndex == 0)
    }

    @Test("the showing tab does not wrap round past either end")
    func stepStopsAtTheEnds() {
        var first = list(active: 0)
        #expect(!first.canMoveActive(by: -1))
        let pastStart = first.moveActive(by: -1)
        #expect(!pastStart)
        #expect(first == list(active: 0))

        var last = list(active: 3)
        #expect(!last.canMoveActive(by: 1))
        let pastEnd = last.moveActive(by: 1)
        #expect(!pastEnd)
        #expect(last == list(active: 3))

        #expect(!list(active: 1).canMoveActive(by: 0))
        #expect(!TabList(tabs: ["A"], activeIndex: 0).canMoveActive(by: 1))
    }

    // MARK: - A step that may cross into the pane beside

    @Test("a step with a neighbour on that side stays on the strip, whatever is beside the pane")
    func stepPrefersTheStrip() {
        #expect(list(active: 1).step(by: 1, besidePaneTabCount: 3) == .along)
        #expect(list(active: 1).step(by: -1, besidePaneTabCount: 3) == .along)
        #expect(list(active: 1).step(by: 1, besidePaneTabCount: nil) == .along)
    }

    /// Past the right end of a pane is the start of the one on its right, and past the left end of a
    /// pane is the end of the one on its left, so `count` names the gap after that pane's last tab.
    @Test("off the end of the strip a tab enters the pane beside at the end nearest it")
    func stepCrossesAtTheNearEnd() {
        #expect(list(active: 3).step(by: 1, besidePaneTabCount: 2) == .across(slot: 0))
        #expect(list(active: 0).step(by: -1, besidePaneTabCount: 2) == .across(slot: 2))
    }

    @Test("with no pane on that side a step off the end goes nowhere")
    func stepStopsAtTheOuterEnds() {
        #expect(list(active: 3).step(by: 1, besidePaneTabCount: nil) == .stays)
        #expect(list(active: 0).step(by: -1, besidePaneTabCount: nil) == .stays)
    }

    @Test("a pane's last tab stays, and so does a step of nothing")
    func stepKeepsTheLastTab() {
        let lone = TabList(tabs: ["A"], activeIndex: 0)
        #expect(lone.step(by: 1, besidePaneTabCount: 2) == .stays)
        #expect(lone.step(by: -1, besidePaneTabCount: 2) == .stays)
        #expect(list(active: 0).step(by: 0, besidePaneTabCount: 2) == .stays)
    }

    /// The promise in the doc comment: the opposite step undoes a crossing, carried out here the way
    /// the app does, by taking the tab out of one list and inserting it into the other.
    @Test("a crossing and the opposite step put both lists back")
    func stepAcrossAndBack() throws {
        var left = TabList(tabs: ["A", "B", "C"], activeIndex: 2)
        var right = TabList(tabs: ["X", "Y"], activeIndex: 1)
        let before = (left, right)

        guard case let .across(slot) = left.step(by: 1, besidePaneTabCount: right.tabs.count) else {
            Issue.record("expected a crossing to the right")
            return
        }
        let leaving = left.remove(at: left.activeIndex)
        right.insert(try #require(leaving), atSlot: slot)
        #expect(right.tabs == ["C", "X", "Y"])
        #expect(right.activeIndex == 0)

        guard case let .across(back) = right.step(by: -1, besidePaneTabCount: left.tabs.count) else {
            Issue.record("expected a crossing back to the left")
            return
        }
        let returning = right.remove(at: right.activeIndex)
        left.insert(try #require(returning), atSlot: back)
        #expect(left == before.0)
        #expect(right.tabs == before.1.tabs)
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

    // MARK: - Leaving

    @Test("the last tab cannot leave")
    func lastTabStays() {
        var single = TabList(tabs: ["A"], activeIndex: 0)
        #expect(!single.canRemove)
        let removed = single.remove(at: 0)
        #expect(removed == nil)
        #expect(single.tabs == ["A"])
    }

    @Test("when the showing tab leaves, the one sliding into its place takes over")
    func showingTabLeaves() {
        var middle = list(active: 1)
        let fromMiddle = middle.remove(at: 1)
        #expect(fromMiddle == "B")
        #expect(middle.tabs[middle.activeIndex] == "C")

        var last = list(active: 3)
        let fromEnd = last.remove(at: 3)
        #expect(fromEnd == "D")
        #expect(last.tabs[last.activeIndex] == "C")
    }

    @Test("when another tab leaves, the showing tab stays showing")
    func otherTabLeaves() {
        var left = list(active: 2)
        let leftOfActive = left.remove(at: 0)
        #expect(leftOfActive == "A")
        #expect(left.tabs[left.activeIndex] == "C")

        var right = list(active: 1)
        let rightOfActive = right.remove(at: 3)
        #expect(rightOfActive == "D")
        #expect(right.tabs[right.activeIndex] == "B")

        var outside = list(active: 1)
        let nothing = outside.remove(at: 4)
        #expect(nothing == nil)
        #expect(outside == list(active: 1))
    }

    // MARK: - Arriving

    @Test("an arriving tab lands in its slot and is the one showing")
    func arrivingTabShows() {
        var tabs = list(active: 3)
        tabs.insert("E", atSlot: 1)
        #expect(tabs.tabs == ["A", "E", "B", "C", "D"])
        #expect(tabs.activeIndex == 1)

        var past = list()
        past.insert("E", atSlot: 9)
        #expect(past.tabs.last == "E")
        #expect(past.activeIndex == 4)
    }

    @Test("an active index past the end is clamped into the list")
    func clampedActiveIndex() {
        #expect(TabList(tabs: ["A", "B"], activeIndex: 5).activeIndex == 1)
        #expect(TabList(tabs: ["A", "B"], activeIndex: -2).activeIndex == 0)
        #expect(TabList<String>(tabs: [], activeIndex: 3).activeIndex == 0)
    }
}

@Suite("Tab move commands")
struct TabMoveCommandTests {
    @Test("the tab moves are conflict-free Window commands on ⌥⌘[, ⌥⌘] and ⇧⌘M")
    func coversTabMoves() throws {
        let expected: [String: CommandShortcut] = [
            "window.moveTabLeft": CommandShortcut(key: "[", modifiers: [.command, .option]),
            "window.moveTabRight": CommandShortcut(key: "]", modifiers: [.command, .option]),
            "window.moveTabToOtherPanel": CommandShortcut(key: "m", modifiers: [.command, .shift])
        ]
        for (id, shortcut) in expected {
            let command = try #require(CommandCatalog.command(for: id))
            #expect(command.category == .window)
            #expect(command.shortcut == shortcut)
            #expect(KeyBindings().conflicts(for: id).isEmpty, "\(id)")
        }
    }
}
