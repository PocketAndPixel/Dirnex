import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The tab strip in the window's title bar row: clear of the title bar's controls, with room left to
/// drag the window by, and a chip that a press cannot use to move the window.
///
/// The strip's measuring is driven through its `titlebarControls`. That the controls report where they
/// really are, and that a real press moves the window or the tab, are for a person with a mouse: a
/// synthetic event does not reach the window server's drag region. What AppKit tells the window server
/// about each view is read here, which is what the bug turned on.
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

    /// The strip's 24 pt inset by 4 is what shares the traffic lights' middle (docs/NOTES.md ▸ Windows),
    /// and the insertion marker stands a point past a chip at each end.
    @Test("a chip sits centered inside the strip, with room for the insertion marker")
    func chipFitsTheStrip() throws {
        let strip = strip(three)
        let chip = try #require(strip.bar.chips.first)
        let frame = strip.frame(of: chip)
        #expect(frame.height == 22)
        #expect(strip.bar.frame.height == 24)
        #expect(abs(frame.midY - strip.bar.bounds.midY) < 0.5)
        #expect(frame.height + 2 <= strip.bar.bounds.height)
    }

    @Test("the path bar sits a wider gap below the strip than the list does below the path bar")
    func gapBelowTheStrip() {
        let hosted = windowedPane()
        let pane = hosted.pane
        pane.view.layoutSubtreeIfNeeded()

        let bar = pane.tabBar.convert(pane.tabBar.bounds, to: nil)
        let path = pane.pathBar.convert(pane.pathBar.bounds, to: nil)
        let list = pane.scrollView.convert(pane.scrollView.bounds, to: nil)
        #expect(bar.minY - path.maxY == PanelViewController.tabStripBottomGap)
        #expect(path.minY - list.maxY == 4)
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

    /// What AppKit tells the window server to leave alone in the title bar's row for `view`, in
    /// `view`'s coordinates. The question is private, and the shipped code does not ask it. A macOS that
    /// renames it fails here, which is the moment for a person to drag a tab again.
    private static func rectLeftAlone(by view: NSView) throws -> NSRect {
        let selector = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")
        try #require(view.responds(to: selector))
        typealias Question = @convention(c) (NSView, Selector) -> NSRect
        return unsafeBitCast(view.method(for: selector), to: Question.self)(view, selector)
    }

    /// `mouseDownCanMoveWindow` alone passed while every drag on a chip moved the window: a plain view
    /// reports no rect whatever it answers there. So the chip's own answer and an empty rect are both
    /// pinned, the second as the reason for the button inside it.
    @Test(
        "the whole of every chip stays out of what the window is dragged by, the blank strip in it"
    )
    func whatMovesTheWindow() throws {
        let strip = strip(three)
        for chip in strip.bar.chips {
            #expect(!chip.mouseDownCanMoveWindow)
            #expect(try Self.rectLeftAlone(by: chip) == .zero)
            let shield = chip.windowDragShield
            let left = chip.convert(try Self.rectLeftAlone(by: shield), from: shield)
            #expect(left.insetBy(dx: -0.5, dy: -0.5).contains(chip.bounds), "\(chip.title): \(left)")
            #expect(chip.bounds.insetBy(dx: -0.5, dy: -0.5).contains(left), "\(chip.title): \(left)")
        }
        #expect(!strip.bar.newButton.mouseDownCanMoveWindow)
        #expect(!strip.bar.overflowButton.mouseDownCanMoveWindow)
        #expect(strip.bar.mouseDownCanMoveWindow)
        #expect(try Self.rectLeftAlone(by: strip.bar) == .zero)
    }

    @Test("the button behind a chip sees no press, takes no focus and is not read out")
    func shieldIsOnlyInTheWay() throws {
        let strip = strip(three)
        let chip = try #require(strip.bar.chips.first)
        for x in [1, chip.labelFrame.midX] {
            let point = chip.convert(NSPoint(x: x, y: chip.bounds.midY), to: chip.superview)
            #expect(chip.hitTest(point) === chip)
        }
        #expect(!chip.windowDragShield.acceptsFirstResponder)
        let read = NSAccessibility.unignoredChildren(from: chip.accessibilityChildren() ?? [])
        let roles = read.compactMap { ($0 as AnyObject).accessibilityRole?() }
        #expect(
            roles.filter { $0 == NSAccessibility.Role.button }.count == 1,
            "only the ×: \(roles)"
        )
    }

    /// Pinned by constraints, an empty button hugs a width of nothing, which at its default priority
    /// outbid the labels and drew every chip about 50 pt wide. `TabStripSqueezeTests` compares chips
    /// with chips, so all of them coming down together passes there.
    @Test("the button behind a chip does not cut its label short")
    func shieldLeavesTheLabelWhole() {
        let strip = strip(three)
        for chip in strip.bar.chips {
            let whole = NSTextField(labelWithString: chip.title)
            whole.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            #expect(chip.labelFrame.width >= whole.intrinsicContentSize.width - 0.5, "\(chip.title)")
        }
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
