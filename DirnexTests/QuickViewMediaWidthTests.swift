import AppKit
import Testing

@testable import Dirnex

/// A movie in a pane's Quick View leaves the panes divider where it was, and free to move
/// (2026-11-20).
///
/// AVKit's inline control bar asks to be 750 pt wide at priority 499, above the 250 the panes hold
/// their widths at, so a player pinned to its pane pushed the pane out to 762 pt the moment a movie
/// opened. Hidden views keep their constraints, so the hidden player and the card's own preferred
/// width held the pane there after the card replaced the player and after Quick View closed, and no
/// drag could narrow it. Measured live in `build/live-copy`: 608.5 / 608.5 became 455 / 762.
///
/// The test host never builds AVKit's bar (it appeared live, in a key window, and never here), so
/// `addControlBarStandIn` puts one with the same constraints into the player, read off the live one.
@Suite("Quick View ▸ a movie leaves the panes their widths")
@MainActor
struct QuickViewMediaWidthTests {
    /// 1001 pt of panes and a 1 pt divider, so the even split is at 500.
    private static let width: CGFloat = 1001

    @Test("a movie neither widens its pane nor holds the divider")
    func movieLeavesDividerFree() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.mp4")
        try await QuickViewMediaFixtures.writeMovie(to: url)
        let panes = try Panes()

        let media = try await panes.preview(url)
        #expect(media.hasItem)
        Self.addControlBarStandIn(to: media.playerView)
        panes.layOut()
        #expect(panes.rightWidth == 500, "opening the movie moved the divider")

        panes.moveDivider(to: 700)
        #expect(panes.rightWidth == 300)
        #expect(media.playerView.frame == media.bounds, "the player follows its pane")
    }

    @Test("the card for a file nothing plays fits a pane narrower than itself")
    func cardFitsNarrowPane() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("film.mkv")
        try QuickViewMediaFixtures.matroskaHeader.write(to: url)
        let panes = try Panes()

        let media = try await panes.preview(url)
        #expect(media.showsCard)
        // The card prefers 280 pt plus its margins, which once held the pane at 312.
        panes.moveDivider(to: 740)
        #expect(panes.rightWidth == 260)
        #expect(media.card.frame == media.bounds)
        #expect(media.card.hintLabel.frame.width <= media.card.bounds.width - 32)
    }

    @Test("with Quick View closed the pane a movie was shown in narrows again")
    func closedPreviewLeavesDividerFree() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("clip.mp4")
        try await QuickViewMediaFixtures.writeMovie(to: url)
        let panes = try Panes()
        let media = try await panes.preview(url)
        Self.addControlBarStandIn(to: media.playerView)
        // The card too, hidden behind the player, as it is once any refused file has been shown.
        media.card.show(.init(name: "film.mkv", container: "Matroska", summary: nil))

        panes.right.hideQuickViewPreview()
        panes.moveDivider(to: 740)
        #expect(panes.rightWidth == 260)
    }

    /// The shape of AVKit's inline control bar as the live player had it: a bar that wants 750 pt at
    /// priority 499, centered, at least 6 pt in from either edge.
    private static func addControlBarStandIn(to playerView: NSView) {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        playerView.addSubview(bar)
        let preferred = bar.widthAnchor.constraint(equalToConstant: 750)
        preferred.priority = NSLayoutConstraint.Priority(499)
        NSLayoutConstraint.activate([
            preferred,
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: playerView.leadingAnchor, constant: 6),
            bar.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            bar.bottomAnchor.constraint(equalTo: playerView.bottomAnchor, constant: -6)
        ])
    }

    /// Two real panes in the app's own split, holding their widths at 250, in a window of their own,
    /// with the divider at the even split.
    @MainActor
    private struct Panes {
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
                contentRect: NSRect(x: 0, y: 0, width: QuickViewMediaWidthTests.width, height: 600),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.animationBehavior = .none
            window.contentViewController = controller
            window.setContentSize(NSSize(width: QuickViewMediaWidthTests.width, height: 600))
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

        /// Show `url` in the right pane's Quick View and wait until the player or the card is up.
        ///
        /// With the caption the window gives a movie: no styles to pick, so the header's style buttons
        /// are away. They hold a pane at about 405 pt, which is the header's own floor and no part of
        /// what is tested here.
        func preview(_ url: URL) async throws -> QuickViewMediaView {
            let caption = QuickViewCaption(name: url.lastPathComponent, position: 1, count: 1)
            right.showQuickViewPreview(of: url, style: .default, caption: caption)
            let surface = try #require(right.quickViewPreview)
            try await settleUntil(within: .seconds(60)) { !surface.flipGate.isLoading }
            layOut()
            return try #require(surface.mediaView)
        }
    }
}
