import AppKit
import DirnexCore
import Foundation
import Testing

@testable import Dirnex

/// Switching tabs from the keyboard: ⇧⌘[ and ⇧⌘] along a strip and on into the other pane, round both
/// strips as one ring.
@MainActor
@Suite("Switching tabs from the keyboard", .serialized)
struct TabSwitchKeyTests {
    private typealias Panes = TabMovePanes

    @Test("⇧⌘] walks the strip, then shows the other pane's first tab there and takes the focus")
    func stepAcrossToTheRight() async throws {
        let panes = try await Self.panesWithTwoOnTheRight()
        let pane = panes.left.pane
        pane.selectTab(at: 0)
        pane.focusTable()

        pane.showNextTab(nil)
        pane.showNextTab(nil)
        #expect(pane.panel.path == Panes.gamma)
        #expect(panes.left.window.firstResponder === pane.tableView)

        pane.showNextTab(nil)

        #expect(panes.right.pane.activeTabIndex == 0)
        #expect(panes.right.pane.panel.path == Panes.other)
        #expect(panes.right.window.firstResponder === panes.right.pane.tableView)
        // The pane left behind keeps showing the tab it was on, and nothing moved.
        #expect(pane.panel.path == Panes.gamma)
        #expect(panes.leftPaths == [Panes.alpha, Panes.beta, Panes.gamma])
        #expect(panes.rightPaths == [Panes.other, Panes.beta])
        #expect(try panes.savedRight().activeIndex == 0)
    }

    @Test("⇧⌘[ off a strip's start shows the other pane's last tab there and takes the focus")
    func stepAcrossToTheLeft() async throws {
        let panes = try await Self.panesWithTwoOnTheRight()
        panes.left.pane.selectTab(at: 0)
        panes.right.pane.selectTab(at: 0)

        panes.right.pane.showPreviousTab(nil)

        #expect(panes.left.pane.activeTabIndex == 2)
        #expect(panes.left.pane.panel.path == Panes.gamma)
        #expect(panes.left.window.firstResponder === panes.left.pane.tableView)
        #expect(panes.right.pane.activeTabIndex == 0)
    }

    @Test("past the far ends the view goes round to the other pane's far end")
    func stepRound() async throws {
        let panes = try await Self.panesWithTwoOnTheRight()
        panes.left.pane.selectTab(at: 2)
        #expect(panes.right.pane.activeTabIndex == 1)

        panes.right.pane.showNextTab(nil)
        #expect(panes.left.pane.activeTabIndex == 0)
        #expect(panes.left.window.firstResponder === panes.left.pane.tableView)

        panes.right.pane.selectTab(at: 0)
        panes.left.pane.showPreviousTab(nil)
        #expect(panes.right.pane.activeTabIndex == 1)
        #expect(panes.right.window.firstResponder === panes.right.pane.tableView)
    }

    @Test("a pane's lone tab hands the focus to the other pane rather than doing nothing")
    func stepFromALoneTab() async throws {
        let panes = try await Panes.make()

        panes.right.pane.showNextTab(nil)

        #expect(panes.left.pane.activeTabIndex == 0)
        #expect(panes.left.window.firstResponder === panes.left.pane.tableView)
        #expect(panes.rightPaths == [Panes.other])
    }

    @Test("with no other pane the view goes round its own strip, as it always did")
    func stepRoundOneStrip() async throws {
        let panes = try await Panes.make()
        let pane = panes.left.pane
        panes.left.host.counterpart = nil
        #expect(pane.activeTabIndex == 2)

        pane.showNextTab(nil)
        #expect(pane.activeTabIndex == 0)

        pane.showPreviousTab(nil)
        #expect(pane.activeTabIndex == 2)
    }

    /// The shared fixture with a second tab on the right, beta, opened beside `other` and showing.
    private static func panesWithTwoOnTheRight() async throws -> TabMovePanes {
        let panes = try await Panes.make()
        panes.right.pane.openInNewTab(Panes.beta)
        try await settleUntil { panes.right.pane.tabs[1].hasLoaded }
        #expect(panes.rightPaths == [Panes.other, Panes.beta])
        return panes
    }
}
