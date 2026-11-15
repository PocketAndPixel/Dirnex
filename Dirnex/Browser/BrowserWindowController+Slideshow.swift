import AppKit
import DirnexCore

/// View ▸ Slideshow (⇧⌘S): a timer that steps the active pane's cursor through its pictures at full
/// size (PLAN.md §M39 ▸ Slice 16). The rules about time and about which file are
/// `QuickViewSlideshow`'s; this is where the show meets the window — the sizes, the surfaces and the
/// deliveries it follows.
///
/// Oleg's calls (2026-11-15): ⇧⌘S works **from anywhere**, opening full screen when Quick View is off
/// or at pane size, as Preview's Slideshow does, and running in full window when that is up; the
/// interval is **a setting**, five seconds by default; the show **loops**; a step of the user's own
/// **carries on** from where it lands; and stopping it **ends the show only**, leaving Quick View up
/// on the picture it reached, for Esc to close.
extension BrowserWindowController {
    /// ⇧⌘S — start a slideshow, or stop the one running.
    @objc func toggleQuickViewSlideshow(_ sender: Any?) {
        if quickViewSlideshow != nil {
            stopQuickViewSlideshow()
        } else if canStartQuickViewSlideshow {
            startQuickViewSlideshow()
        } else {
            NSSound.beep()
        }
    }

    /// Whether ⇧⌘S has anything to show: a picture among the rows the active pane displays.
    var canStartQuickViewSlideshow: Bool {
        let pane = focusedPanel
        let rows = pane.panel.displayedEntries
        return Slideshow.firstSlide(from: pane.slideshowCursorIndex, in: rows) != nil
    }

    /// The size a slideshow runs at, given the size Quick View is at when ⇧⌘S is pressed: full window
    /// stays full window, and anything smaller opens full screen, which is where a slideshow is
    /// watched.
    static func slideshowMode(from mode: QuickViewMode) -> QuickViewMode {
        mode.isFullSize ? mode : .fullScreen
    }

    private func startQuickViewSlideshow() {
        let pane = focusedPanel
        setQuickViewMode(Self.slideshowMode(from: quickViewMode))
        // After the size, which may have stepped the cursor off `..`. A cursor already on a picture
        // keeps it, so the one on screen gets its full turn.
        if let first = Slideshow.firstSlide(
            from: pane.slideshowCursorIndex,
            in: pane.panel.displayedEntries
        ), first != pane.slideshowCursorIndex {
            pane.moveCursor(toDisplayedRow: first)
        }
        let slideshow = QuickViewSlideshow(
            pane: pane,
            interval: { .seconds(AppPreferences.shared.slideshowInterval) },
            advance: { [weak self] row in self?.turnSlideshowPage(to: row) }
        )
        slideshow.onRunOut = { [weak self] in self?.stopQuickViewSlideshow() }
        quickViewSlideshow = slideshow
        slideshowStateDidChange()
    }

    /// End the show and nothing else: Quick View stays at its size on the picture the show reached,
    /// whatever size it opened from (Oleg's call, 2026-11-15, after the first version put a show
    /// started from the list back in the list). ⇧⌘S's stop, the header's mark, a show that ran out of
    /// pictures or lost its folder, and Esc or a size key on their way past all end it here.
    func stopQuickViewSlideshow() {
        guard let slideshow = quickViewSlideshow else { return }
        quickViewSlideshow = nil
        slideshow.end()
        slideshowStateDidChange()
    }

    /// Step to `row` with the page turn ← / → use, always from the right: after the last picture the
    /// first one comes in as the next, not as a step back.
    private func turnSlideshowPage(to row: Int) {
        guard let pane = quickViewSlideshow?.pane else { return }
        guard let preview = activeFullSizePreview else {
            pane.moveCursor(toDisplayedRow: row)
            return
        }
        preview.flip(steps: 1) { pane.moveCursor(toDisplayedRow: row) }
    }

    /// A full-size surface has been handed `active`'s cursor file, or has finished drawing it. The
    /// one funnel the show follows: a pane that is no longer the show's, or has left its folder, ends
    /// it, and anything else tells the countdown whether the picture is there yet.
    func quickViewSlideshowSurfaceDidUpdate(
        _ preview: QuickViewPreviewView?,
        from active: PanelViewController
    ) {
        guard let slideshow = quickViewSlideshow, preview === activeFullSizePreview, let preview else { return }
        guard slideshow.isStill(showing: active) else {
            stopQuickViewSlideshow()
            return
        }
        slideshow.surfaceDidUpdate(awaitingContent: preview.isAwaitingContent)
    }

    /// Put the header's indicator in step with the show, and bring a faded full-screen header up for
    /// a moment so starting or stopping is seen.
    private func slideshowStateDidChange() {
        refreshQuickViewCaption()
        activeFullSizePreview?.revealFloatingHeader()
        // The first delivery, for a show that changed no size and moved no cursor: nothing else would
        // tell it the picture on screen is already there.
        quickViewSlideshowSurfaceDidUpdate(activeFullSizePreview, from: focusedPanel)
    }
}
