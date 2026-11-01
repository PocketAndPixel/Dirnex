import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The tab strip in the window's title bar row: clear of the title bar's controls, with room left to
/// drag the window by, and a chip that a press cannot use to move the window.
///
/// The strip's measuring is driven through its `titlebarControls`. That the controls report where they
/// really are, and that a real press moves the window or the tab, are for a person with a mouse: a
/// synthetic event does not reach the window server's drag region.
@MainActor
@Suite("The tab strip in the title bar's row", .serialized)
struct TabStripTitlebarTests {
    private let three = TabStripFixture.folders(["Downloads", "Documents", "Library"])
    private let nine = TabStripFixture.folders(TabStripFixture.titles)

    private func strip(
        _ items: [TabBarView.Item],
        width: CGFloat = 800,
        fromLeft: Double = 0,
        fromRight: Double = 0
    ) -> TabStripFixture {
        let strip = TabStripFixture(items, width: width)
        strip.bar.titlebarControls = {
            TitlebarClearance.Controls(fromLeft: fromLeft, fromRight: fromRight)
        }
        strip.bar.needsLayout = true
        strip.window.layoutIfNeeded()
        return strip
    }

    @Test("controls at the left edge move the first chip past them, and the strip keeps its width")
    func clearsTheLeftControls() throws {
        let strip = strip(three, fromLeft: 118)
        let first = try #require(strip.bar.chips.first)
        #expect(abs(strip.frame(of: first).minX - 118) < 0.5)
        #expect(abs(strip.bar.frame.width - 800) < 0.5)
    }

    @Test("with no controls in its way the first chip starts at the strip's end")
    func nothingToClear() throws {
        let strip = strip(three)
        let first = try #require(strip.bar.chips.first)
        #expect(strip.frame(of: first).minX < 0.5)
    }

    @Test("an overfull strip stops short of the controls at the right edge")
    func clearsTheRightControls() {
        let strip = strip(nine, fromRight: 100)
        let edge = strip.bar.newButton.convert(strip.bar.newButton.bounds, to: strip.bar).maxX
        #expect(edge <= 800 - 100 + 0.5)
    }

    @Test("however full the strip, its end stays free to drag the window by")
    func keepsRoomToGrab() {
        let strip = strip(nine)
        #expect(!strip.bar.overflowButton.isHidden)
        let edge = strip.bar.newButton.convert(strip.bar.newButton.bounds, to: strip.bar).maxX
        #expect(edge <= 800 - TabBarView.windowGrabWidth + 0.5)
    }

    @Test("what the controls cover comes out of the room for chips, and more tabs go behind the »")
    func clearanceCountsTowardOverflow() {
        let open = strip(nine)
        let covered = strip(nine, fromLeft: 300)
        #expect(covered.bar.visibleRange.count < open.bar.visibleRange.count)
        let edge = covered.bar.newButton.convert(covered.bar.newButton.bounds, to: covered.bar).maxX
        #expect(edge <= 800 - TabBarView.windowGrabWidth + 0.5)
        covered.expectReadableLabels()
    }

    /// Once a strip has measured, a change that does not resize it still lands: the sidebar moving
    /// the left pane along at one size, or the license label coming and going.
    @Test("a strip measured again follows the controls back out")
    func followsTheControls() throws {
        let strip = TabStripFixture(three, width: 800)
        nonisolated(unsafe) var fromLeft = 118.0
        strip.bar.titlebarControls = {
            TitlebarClearance.Controls(fromLeft: fromLeft, fromRight: 0)
        }
        strip.bar.needsLayout = true
        strip.window.layoutIfNeeded()
        let first = try #require(strip.bar.chips.first)
        #expect(abs(strip.frame(of: first).minX - 118) < 0.5)

        fromLeft = 0
        strip.bar.needsLayout = true
        strip.window.layoutIfNeeded()
        #expect(strip.frame(of: first).minX < 0.5)
    }

    /// `mouseDownCanMoveWindow` is what the title bar's row asks of whatever is under a press. A plain
    /// view answers `true` (the blank strip, which should), and so would a chip without its override.
    @Test(
        "a press on a chip or a button stays on it, and a press on the blank strip moves the window"
    )
    func whatMovesTheWindow() throws {
        let strip = strip(three)
        let chip = try #require(strip.bar.chips.first)
        #expect(!chip.mouseDownCanMoveWindow)
        #expect(!strip.bar.newButton.mouseDownCanMoveWindow)
        #expect(!strip.bar.overflowButton.mouseDownCanMoveWindow)
        #expect(strip.bar.mouseDownCanMoveWindow)
    }

    @Test("a pane's only tab has no ×, and the label takes the room")
    func loneChipCannotClose() throws {
        let alone = TabStripFixture.folders(["Downloads"])
        let strip = TabStripFixture(alone, width: 800)
        let lone = try #require(strip.bar.chips.first)
        #expect(!lone.canClose)
        let width = strip.frame(of: lone).width

        strip.show(three, active: 0)
        let first = try #require(strip.bar.chips.first)
        #expect(first.canClose)
        // The ×'s 12 and the 5 before it, on the same title.
        #expect(abs(strip.frame(of: first).width - width - 17) < 0.5)
    }

    @Test("a pane's only tab starts no drag: it has nowhere to go")
    func loneChipStaysPut() throws {
        let strip = TabStripFixture(TabStripFixture.folders(["Downloads"]), width: 800)
        let chip = try #require(strip.bar.chips.first)
        let press = try #require(Self.mouse(.leftMouseDown, at: .zero, in: strip.window))
        let drag = try #require(Self.mouse(
            .leftMouseDragged,
            at: NSPoint(x: 40, y: 0),
            in: strip.window
        ))
        chip.mouseDown(with: press)
        chip.mouseDragged(with: drag)
        #expect(strip.bar.draggedIndex == nil)
    }

    private static func mouse(
        _ type: NSEvent.EventType,
        at location: NSPoint,
        in window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }
}
