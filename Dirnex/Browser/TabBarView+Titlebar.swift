import AppKit
import DirnexCore

/// The strip in the window's title bar row. It takes that row over from the title bar, which leaves
/// it two jobs the title bar used to do by being empty.
///
/// **It stays out from under the title bar's controls.** They sit on top of it, so a chip under one
/// could be seen and not clicked. Where the strip is and where they are decide how far in its chips
/// start and stop (`TitlebarClearance`), and the strip itself keeps the pane's whole width so its
/// drop target does not shrink.
///
/// **It leaves room to drag the window by.** Everything on the strip that is not a chip or a button
/// moves the window, because a drag in this row is the window server's unless a control is in the way
/// (`TabChipView.windowDragShield`). With both strips full and the sidebar closed nothing would be
/// left, so each keeps a little at its end however many tabs it holds. A tab that no longer fits for
/// it goes behind the ».
extension TabBarView {
    /// What the strip keeps free at its end to grab the window by.
    static let windowGrabWidth: CGFloat = 40

    /// Move the chips in from whatever covers the strip's ends now. Only the stack moves, inside a
    /// strip whose own frame the pane decides, so this cannot change what it was worked out from.
    func updateTitlebarClearance() {
        var clearance = TitlebarClearance.none
        if let window, let controls = titlebarControls?() {
            let strip = convert(bounds, to: nil)
            clearance = TitlebarClearance(
                stripMinX: Double(strip.minX),
                stripMaxX: Double(strip.maxX),
                windowWidth: Double(window.frame.width),
                controls: controls
            )
        }
        let leading = CGFloat(clearance.leading)
        let trailing = -CGFloat(clearance.trailing) - Self.windowGrabWidth
        if stackLeading.constant != leading { stackLeading.constant = leading }
        if stackTrailing.constant != trailing { stackTrailing.constant = trailing }
    }

    /// The strip's width its chips and buttons cannot have.
    var reservedWidth: CGFloat {
        stackLeading.constant - stackTrailing.constant
    }

    /// A chip's × was clicked. A second click on the same spot is not a double-click on the title bar,
    /// whatever is under the pointer by then (`BrowserContentView`).
    func chipDidClose(_ chip: TabChipView) {
        (window?.contentView as? BrowserContentView)?.ignoresNextDoubleClick = true
        delegate?.tabBar(self, didCloseTabAt: chip.index)
    }
}

extension BrowserWindowController {
    /// How far the title bar's controls reach in from the window's edges. None in full screen, where
    /// the title bar is a window of its own that comes down over the strips only when summoned, and
    /// its views' frames say nothing about this window.
    var titlebarControls: TitlebarClearance.Controls {
        guard let window, !window.styleMask.contains(.fullScreen) else { return .none }
        let toggle = sidebarToggleAccessory.view
        return TitlebarClearance.Controls(
            fromLeft: Double(toggle.convert(toggle.bounds, to: nil).maxX),
            fromRight: Double(
                licenseLabel.view.frame.width + updateIndicatorAccessory.view.frame.width
            )
        )
    }

    /// Have both strips measure again, for a change that does not resize them.
    func tabStripsNeedLayout() {
        for panel in [leftPanel, rightPanel] {
            panel.tabBar.needsLayout = true
        }
    }
}
