import AppKit
import Testing

@testable import Dirnex

/// Two real panes in the app's own split, holding their widths at 250 as `BrowserWindowController`
/// sets them, in a window of their own, with the divider at the even split. For the tests that ask
/// whether something shown in a pane's Quick View moves the divider or holds it (2026-11-20).
///
/// The divider is moved with `setPosition(_:ofDividerAt:)`. Measured live on the same day, it met
/// the same resistance a drag did: both left a pane at 762 pt that something inside it held there.
@MainActor
struct QuickViewPaneSplit {
    /// 1001 pt of panes and a 1 pt divider, so the even split is at 500.
    static let width: CGFloat = 1001

    let split: NSSplitView
    let right: PanelViewController
    /// The panes' hosts and the controller, kept alive: a pane's `host` is weak.
    private let kept: [AnyObject]

    init() throws {
        let controller = PanesSplitViewController()
        controller.splitView = HairlineSplitView()
        controller.splitView.isVertical = true
        controller.splitView.dividerStyle = .thin
        let (left, leftHost) = hostedPane()
        let (right, rightHost) = hostedPane()
        for pane in [left, right] {
            let item = NSSplitViewItem(viewController: pane)
            item.holdingPriority = NSLayoutConstraint.Priority(250)
            item.canCollapse = false
            controller.addSplitViewItem(item)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.animationBehavior = .none
        window.contentViewController = controller
        window.setContentSize(NSSize(width: Self.width, height: 600))
        RetainedWindows.all.append(window)
        split = controller.splitView
        self.right = right
        kept = [controller, leftHost, rightHost]
        moveDivider(to: 500)
        try #require(rightWidth == 500)
    }

    var rightWidth: CGFloat { split.subviews[1].frame.width }

    func layOut() {
        split.layoutSubtreeIfNeeded()
    }

    func moveDivider(to position: CGFloat) {
        split.setPosition(position, ofDividerAt: 0)
        layOut()
    }
}
