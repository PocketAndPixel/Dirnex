import AppKit
import Testing

@testable import Dirnex

/// The panes divider holds at the even split while dragged near it (`PanesSplitViewController`).
/// The drags here are real ones: `NSSplitView` tracks a drag in its own loop, pulling the drags and
/// the release off the event queue, so queuing those and then sending the press runs AppKit's whole
/// path, delegate call included. That is what pins the part a pure test cannot, that AppKit asks
/// the controller at all.
@Suite("Panes divider detent")
@MainActor
struct PanesDividerDetentTests {
    /// 801 pt wide with a 1 pt divider, so the even split is at exactly 400.
    private static let width: CGFloat = 801
    private static let equal: CGFloat = 400

    /// Kept for the life of the process: tearing a window down while it is still settling crashes a
    /// later test (docs/NOTES.md ▸ Testing).
    private static var windows: [NSWindow] = []

    @Test("the divider lands on the even split within the detent, and nowhere else")
    func positionRule() {
        let detent = PanesSplitViewController.equalWidthDetent
        func position(_ proposed: CGFloat) -> CGFloat {
            PanesSplitViewController.position(for: proposed, equal: Self.equal)
        }
        #expect(position(Self.equal - detent) == Self.equal)
        #expect(position(Self.equal + detent) == Self.equal)
        #expect(position(Self.equal + 3) == Self.equal)
        #expect(position(Self.equal - detent - 0.5) == 391.5)
        #expect(position(Self.equal + detent + 0.5) == 408.5)
    }

    @Test("the even split leaves both panes the same width")
    func equalPositionSplitsEvenly() {
        let splitView = Self.makeSplit()
        #expect(PanesSplitViewController.equalPosition(in: splitView) == Self.equal)
        splitView.setPosition(Self.equal, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        #expect(splitView.subviews[0].frame.width == splitView.subviews[1].frame.width)
    }

    @Test("the controller answers the delegate call AppKit asks during a drag")
    func respondsToConstrainSplitPosition() {
        // By selector string: `#selector` resolves against the protocol and would keep naming the
        // right selector after the class stopped implementing it (docs/NOTES.md ▸ Delegates in Swift 6).
        let selector = NSSelectorFromString("splitView:constrainSplitPosition:ofSubviewAt:")
        #expect(PanesSplitViewController().responds(to: selector))
    }

    @Test("a drag released near the even split leaves the panes equal")
    func dragReleasedInsideDetent() throws {
        let splitView = Self.makeSplit()
        try Self.drag(splitView, through: [340, 380, 395])
        #expect(splitView.subviews[0].frame.width == Self.equal)
        #expect(splitView.subviews[0].frame.width == splitView.subviews[1].frame.width)
    }

    @Test("the same drag on a split without the detent stops where the pointer did")
    func dragWithoutDetent() throws {
        // The negative control: without it, the test above cannot tell the detent from a drag that
        // happens to land on the middle.
        let splitView = Self.makeSplit(LockableDividerSplitViewController())
        try Self.drag(splitView, through: [340, 380, 395])
        #expect(abs(splitView.subviews[0].frame.width - 395) <= 1)
    }

    @Test("past the detent the divider follows the pointer")
    func dragPastDetent() throws {
        let splitView = Self.makeSplit()
        try Self.drag(splitView, through: [380, 400, 430])
        #expect(abs(splitView.subviews[0].frame.width - 430) <= 1)
    }

    @Test("the trackpad taps once each time a drag enters the detent")
    func feedbackOnEntry() throws {
        let controller = PanesSplitViewController()
        var taps = 0
        controller.detentFeedback = { taps += 1 }
        let splitView = Self.makeSplit(controller)
        // In at 395, held through 405, out at 430, back in at 405.
        try Self.drag(splitView, through: [380, 390, 395, 400, 405, 430, 440, 405, 400])
        #expect(taps == 2)
        #expect(splitView.subviews[0].frame.width == Self.equal)
    }

    @Test("a drag that starts on the even split leaves it without a tap")
    func noFeedbackLeaving() throws {
        let controller = PanesSplitViewController()
        var taps = 0
        controller.detentFeedback = { taps += 1 }
        let splitView = Self.makeSplit(controller, at: Self.equal)
        try Self.drag(splitView, through: [403, 397, 430])
        #expect(taps == 0)
        #expect(abs(splitView.subviews[0].frame.width - 430) <= 1)
    }

    @Test("a queued release from another window cannot end the divider drag")
    func queuedReleaseFromAnotherWindow() throws {
        let other = Self.makeSplit()
        let otherWindow = try #require(other.window)
        let release = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 200, y: 150),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: otherWindow.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ))
        let splitView = Self.makeSplit()
        let window = try #require(splitView.window)
        NSApp.postEvent(release, atStart: true)
        defer {
            var foundRelease = false
            let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
            let fixtureNumbers = [otherWindow.windowNumber, window.windowNumber]
            // Clean up only these two fixtures, including an unfinished drag on a failing run.
            // At most three drags and two releases were posted. Leave unrelated events queued.
            for _ in 0..<5 {
                guard let pending = NSApp.nextEvent(
                    matching: mask, until: .distantPast, inMode: .eventTracking, dequeue: false
                ), fixtureNumbers.contains(pending.windowNumber) else {
                    break
                }
                _ = NSApp.nextEvent(
                    matching: mask, until: .distantPast, inMode: .eventTracking, dequeue: true
                )
                foundRelease = foundRelease || pending.windowNumber == otherWindow.windowNumber
            }
            #expect(foundRelease)
        }
        try Self.drag(splitView, through: [380, 400, 430])
        #expect(abs(splitView.subviews[0].frame.width - 430) <= 1)
    }

    @Test("setting the position in code snaps too, without a tap")
    func programmaticPositionIsSilent() {
        let controller = PanesSplitViewController()
        var taps = 0
        controller.detentFeedback = { taps += 1 }
        let splitView = Self.makeSplit(controller)
        splitView.setPosition(396, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        #expect(splitView.subviews[0].frame.width == Self.equal)
        #expect(taps == 0)
    }

    /// A two-pane split laid out like the app's (holding priority 250, no collapsing) in a window of
    /// its own, with the divider at `position`.
    private static func makeSplit(
        _ controller: LockableDividerSplitViewController = PanesSplitViewController(),
        at position: CGFloat = 300
    ) -> NSSplitView {
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        for _ in 0..<2 {
            let pane = NSViewController()
            pane.view = NSView()
            let item = NSSplitViewItem(viewController: pane)
            item.holdingPriority = NSLayoutConstraint.Priority(250)
            item.canCollapse = false
            controller.addSplitViewItem(item)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: 300))
        // A newly shown window can still be scaled by its opening animation. AppKit transforms
        // posted mouse coordinates through that scale when it takes them off the event queue.
        window.animationBehavior = .none
        window.orderFront(nil)
        windows.append(window)
        let splitView = controller.splitView
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(position, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        return splitView
    }

    /// Presses on the divider, drags the pointer through `steps` and releases at the last one.
    private static func drag(_ splitView: NSSplitView, through steps: [CGFloat]) throws {
        let window = try #require(splitView.window)
        let last = try #require(steps.last)
        func event(_ type: NSEvent.EventType, at x: CGFloat) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: splitView.convert(NSPoint(x: x, y: splitView.bounds.midY), to: nil),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
        }
        let start = splitView.subviews[0].frame.maxX + splitView.dividerThickness / 2
        let press = try event(.leftMouseDown, at: start)
        let drags = try steps.map { try event(.leftMouseDragged, at: $0) }
        let release = try event(.leftMouseUp, at: last)
        let releaseLocation = release.locationInWindow
        let queued = drags + [release]
        // Tracking reads NSApp's queue, including releases from other windows. Prepend the whole
        // gesture in order, with no suspension before the press, so an old release cannot end it.
        for queuedEvent in queued.reversed() {
            NSApp.postEvent(queuedEvent, atStart: true)
        }
        window.sendEvent(press)
        #expect(NSApp.currentEvent?.type == .leftMouseUp)
        #expect(NSApp.currentEvent?.windowNumber == window.windowNumber)
        #expect(NSApp.currentEvent?.locationInWindow == releaseLocation)
        splitView.layoutSubtreeIfNeeded()
    }
}
