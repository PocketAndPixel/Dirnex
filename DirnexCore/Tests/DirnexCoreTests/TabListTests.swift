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
