import AppKit

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
