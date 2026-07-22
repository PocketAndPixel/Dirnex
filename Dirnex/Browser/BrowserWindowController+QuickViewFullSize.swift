import AppKit
import DirnexCore

/// Where Quick View's two full-size surfaces sit, and how the full-screen one coordinates with the
/// native full-screen space (PLAN.md §M11). Split out of `BrowserWindowController+QuickView`, which
/// owns the mode machine; this is only geometry and window state.
///
/// Both surfaces are subviews of the window's content view rather than of the thing they cover:
/// the panes' container is an `NSSplitView`, which treats a plain subview as a pane. Constraining
/// a content-view subview to the split view's own anchors is legal (they share an ancestor) and
/// tracks it exactly as the divider, the sidebar and the drawer move.
extension BrowserWindowController {
    /// The ⌃⇧Q surface: both panes and the divider, and nothing else. The sidebar, the terminal
    /// drawer and the function bar stay usable, which is what separates this mode from full screen
    /// rather than making it a smaller version of it. Its header is pinned — this is a working
    /// surface, and a name that fades out is one you have to wave at the screen to read.
    func ensureFullWindowPreview() -> QuickViewPreviewView {
        if let preview = fullWindowPreview { return preview }
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .pinned)
        let panes = panesSplitViewController.view
        install(preview, pinnedTo: panes)
        fullWindowPreview = preview
        return preview
    }

    /// The ⌃⌥Q surface: the window's whole content view, black behind the document, no chrome.
    /// The window carries `.fullSizeContentView`, so this reaches the top of the screen with
    /// nothing but the auto-hiding title bar over it. Its header floats and fades — this is a
    /// viewing surface, and permanent chrome is the thing being escaped.
    func ensureFullScreenPreview() -> QuickViewPreviewView {
        if let preview = fullScreenPreview { return preview }
        let preview = QuickViewPreviewView(backingColor: .black, header: .floating)
        guard let content = window?.contentView else { return preview }
        // Without this the fading header never appears: a window does not post mouse-moved events
        // by default, so the tracking area that reveals the strip is never told the pointer moved.
        // Verified live — two synthetic moves over the photo left the header at zero alpha.
        window?.acceptsMouseMovedEvents = true
        install(preview, pinnedTo: content)
        fullScreenPreview = preview
        return preview
    }

    /// Add `preview` to the window's content view and pin it over `anchor`'s bounds. Added last so
    /// it draws over everything already in the content view.
    private func install(_ preview: QuickViewPreviewView, pinnedTo anchor: NSView) {
        guard let content = window?.contentView else { return }
        preview.isHidden = true
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: anchor.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: anchor.trailingAnchor),
            preview.topAnchor.constraint(equalTo: anchor.topAnchor),
            preview.bottomAnchor.constraint(equalTo: anchor.bottomAnchor)
        ])
    }

    /// The surface the current mode is showing on, or `nil` at the two sizes that have none.
    var activeFullSizePreview: QuickViewPreviewView? {
        switch quickViewMode {
        case .fullWindow: fullWindowPreview
        case .fullScreen: fullScreenPreview
        case .off, .pane: nil
        }
    }

    // MARK: - The two-finger swipe

    /// Flip between files by swiping two fingers across the trackpad while a full-size Quick View is
    /// up (PLAN.md §M11) — the pointing-device twin of ← / →, at the same two sizes, because those
    /// are the ones where the file list is behind the preview.
    ///
    /// The gesture is **`NSEvent.trackSwipeEvent`**, the system's own fluid-swipe tracking — the
    /// same API Safari and Preview turn pages with. This replaced a hand-rolled state machine that
    /// went through five rounds of tuning without converging, because every quantity it needed is
    /// one the OS already owns: how far is far enough, what counts as horizontal, how to compensate
    /// for pointer acceleration (measured at up to 5.18× between a slow swipe and a fast one over
    /// the same distance), when the user has changed their mind, and how to animate the rest of the
    /// way. The handler below decides nothing except *which file* — the feel is the platform's, so
    /// it matches every other app on the machine for free.
    ///
    /// Still a window-scoped monitor rather than a `scrollWheel(with:)` override, for the same
    /// reason Esc needs one: the pointer sits over `PDFView` or the out-of-process `QLPreviewView`,
    /// and both eat scroll before it could bubble.
    func installQuickViewSwipeMonitor() {
        quickViewSwipeMonitor = NSEvent
            .addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, beginQuickViewSwipe(event) else { return event }
                return nil
            }
    }

    /// Hand `event` to the system's swipe tracker if it opens a horizontal gesture over the preview.
    /// Returns whether it was taken, in which case the tracker owns the rest of the gesture.
    private func beginQuickViewSwipe(_ event: NSEvent) -> Bool {
        guard
            // The user's own "Swipe between pages" setting. Off means they have told the OS they do
            // not want two-finger swipe navigation, so Dirnex does not invent its own; ← / → still
            // walk the list.
            NSEvent.isSwipeTrackingFromScrollEventsEnabled,
            window?.isKeyWindow == true,
            quickViewMode.isFullSize,
            // Only the event that opens a gesture: `trackSwipeEvent` takes the stream from there.
            event.phase == .began,
            // A trackpad (or Magic Mouse) only. A notched wheel's horizontal tilt is a coarse click.
            event.hasPreciseScrollingDeltas,
            // Strictly horizontal, so a vertical scroll is never swallowed and a PDF still scrolls
            // as it always did. A gesture opening with no delta at all is left alone rather than
            // guessed at — measured, a real swipe's `.began` already carries its direction.
            abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
            let preview = activeFullSizePreview,
            // Over the preview itself: in full-window mode the sidebar is still there beside it,
            // and scrolling *it* is the sidebar's business.
            preview.bounds.contains(preview.convert(event.locationInWindow, from: nil))
        else { return false }

        trackQuickViewSwipe(event, on: preview)
        return true
    }

    /// Follow the gesture the system is tracking. `gestureAmount` runs 0 → ±1 as the swipe
    /// progresses and keeps running after the fingers lift, as the OS animates it either home to 0
    /// (the user pulled back) or out to ±1 (the flip is happening) — so the file's whole travel,
    /// including the part after release, is the system's animation and not ours.
    ///
    /// The two dampen thresholds are how the *ends of the list* are expressed, and they are the
    /// reason there is no bounds check drawn by hand here: a direction with no file left is pinned
    /// at 0, so the OS rubber-bands the fingers and springs the file back — Safari's feel at the end
    /// of its history, for free and in the one place that can produce it while the fingers are still
    /// down. A clamp inside the handler could only refuse *after* the flip had already been animated.
    private func trackQuickViewSwipe(_ event: NSEvent, on preview: QuickViewPreviewView) {
        let panel = focusedPanel
        event.trackSwipeEvent(
            options: .lockDirection,
            // Negative amounts flip forward (see the sign note below), so each end pins the side
            // that would walk off it.
            dampenAmountThresholdMin: panel.canStepCursor(by: 1) ? -1 : 0,
            max: panel.canStepCursor(by: -1) ? 1 : 0
        ) { [weak self, weak preview] amount, _, isComplete, stop in
            guard let preview, preview.window != nil else {
                stop.pointee = true
                return
            }
            preview.setSwipeOffset(amount * preview.bounds.width)
            guard isComplete else { return }
            // Landed home: the user changed their mind, and the file is already back at centre.
            guard abs(amount) > 0.5 else { return }
            // Fingers left carry the file left and bring the *next* one on, so the sign inverts —
            // and with it the gesture follows the user's "natural scrolling" setting, exactly as
            // every other scroll on their Mac does.
            let steps = amount < 0 ? 1 : -1
            // Belt to the dampening's braces: a dampened amount is pulled back towards the
            // threshold rather than clamped at it, so the end of the list is checked again here
            // before anything is dealt. Nothing to flip to means the file goes back to centre.
            guard self?.focusedPanel.canStepCursor(by: steps) == true else {
                preview.resetSwipe()
                return
            }
            preview.completeSwipe(steps: steps) { self?.focusedPanel.stepCursor(by: steps) }
        }
    }

    // MARK: - The native full-screen space

    /// Enter the full-screen space for `.fullScreen`, and leave it again when the mode moves on —
    /// but only if ⌃⌥Q is what put the window there. A user who was already full-screen keeps
    /// their space when the preview closes; `didEnterFullScreenForQuickView` is the whole
    /// difference between that and evicting them.
    func syncFullScreenSpace(for mode: QuickViewMode) {
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        if mode == .fullScreen {
            guard !isFullScreen else { return }
            didEnterFullScreenForQuickView = true
            window.toggleFullScreen(nil)
        } else if didEnterFullScreenForQuickView {
            didEnterFullScreenForQuickView = false
            if isFullScreen { window.toggleFullScreen(nil) }
        }
    }

    /// Watch for the user leaving full screen by the green button or ⌃⌘F, so the mode doesn't go
    /// on claiming something untrue. A selector-based observer (not a block/token one) because the
    /// class's `deinit` is nonisolated and tears observers down with `removeObserver(self)`.
    func observeQuickViewFullScreen() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickViewWindowWillExitFullScreen(_:)),
            name: NSWindow.willExitFullScreenNotification,
            object: window
        )
    }

    @objc func quickViewWindowWillExitFullScreen(_ notification: Notification) {
        guard quickViewMode == .fullScreen else { return }
        // The space is already on its way out, so clear the flag first: `setQuickViewMode` must
        // not answer by toggling full screen *again* from inside the exit it is reacting to.
        didEnterFullScreenForQuickView = false
        closeQuickView()
    }
}

// MARK: - Menu state

/// The three Quick View sizes check themselves, so the View menu reads as one exclusive set rather
/// than three independent switches — which is what the flat toggles behave like. Validated here
/// rather than on the pane because the commands are the window's (see `CommandBinding`); every
/// other selector the window answers is always enabled, as it was before this conformance existed.
extension BrowserWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleQuickViewPanel(_:)):
            menuItem.state = quickViewMode == .pane ? .on : .off
        case #selector(toggleQuickViewFullWindow(_:)):
            menuItem.state = quickViewMode == .fullWindow ? .on : .off
        case #selector(toggleQuickViewFullScreen(_:)):
            menuItem.state = quickViewMode == .fullScreen ? .on : .off
        default:
            break
        }
        return true
    }
}
