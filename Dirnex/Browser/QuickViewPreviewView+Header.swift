import AppKit

/// The header's behaviours that are more than drawing a caption: its buttons, and the floating
/// header's fade in full screen. Split out of `QuickViewPreviewView` when the Close button arrived
/// (2026-10-18), because the button is what made the fade need a rule about the pointer.
extension QuickViewPreviewView {
    /// What the header's Close button does. Set by whoever owns the surface: the window for the two
    /// full sizes, the covered pane for ⌃Q. Ignored when this surface has no header.
    var onClose: (() -> Void)? {
        get { headerView?.onClose }
        set { headerView?.onClose = newValue }
    }

    /// What a click on one of the header's styles does — `1` or `2` by hand. Set by the same owners
    /// as `onClose`, for the same reason.
    var onPickStyle: ((QuickViewRenderStyle) -> Void)? {
        get { headerView?.onPickStyle }
        set { headerView?.onPickStyle = newValue }
    }

    // MARK: - The floating header's fade

    /// How long the floating header stays up after the pointer last moved.
    static let headerFadeDelay: TimeInterval = 2.5

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard headerStyle == .floating else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        revealFloatingHeader()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        revealFloatingHeader()
    }

    /// Fade the floating header in and arm its fade-out. Every movement restarts the delay, so the
    /// strip stays up while the pointer is busy and goes away once it settles.
    private func revealFloatingHeader() {
        guard let headerView, headerStyle == .floating else { return }
        headerFadeGeneration += 1
        headerView.animator().alphaValue = 1
        fadeFloatingHeader(after: Self.headerFadeDelay, generation: headerFadeGeneration)
    }

    /// Fade the header out once `delay` has passed, unless the pointer is resting on it. That is
    /// where the Close button is, and a pointer that has come to a stop on it is about to click: a
    /// header that faded from under it would leave the click nothing to land on, since a faded header
    /// keeps its button out of reach. So the fade waits and asks again, until the pointer moves off
    /// or a newer reveal takes over.
    private func fadeFloatingHeader(after delay: TimeInterval, generation: Int) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let headerView, headerFadeGeneration == generation else { return }
            if headerView.isUnderPointer {
                fadeFloatingHeader(after: delay, generation: generation)
            } else {
                headerView.animator().alphaValue = 0
            }
        }
    }
}

extension QuickViewHeaderView {
    /// Whether the pointer is over the strip right now. Read from the window rather than from a
    /// tracking area of its own, because the question is only asked when a fade comes due.
    var isUnderPointer: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}
