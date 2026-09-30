import AppKit

/// Quick View's two render styles for the window: the `1` / `2` keys and View menu items that pick
/// one, and the preference every surface a window drives is read from (PLAN.md §M16). Split out of
/// `BrowserWindowController+QuickView` when tables became the second family of dual-style file and
/// that file reached SwiftLint's length ceiling.
extension BrowserWindowController {
    // MARK: - Source or page

    /// View ▸ Quick View ▸ View Source / View Rendered Page, and the `1` / `2` keys behind them.
    @objc func showQuickViewSource(_ sender: Any?) {
        setQuickViewRenderStyle(.source)
    }

    @objc func showQuickViewRenderedPage(_ sender: Any?) {
        setQuickViewRenderStyle(.rendered)
    }

    /// Switch the app-wide style for the kind of file on screen, and re-render it.
    ///
    /// The preference is the single source of truth and every open window follows it, so this
    /// writes it and lets `quickViewRenderStyleDidChange` drive the re-delivery — including this
    /// window's. Setting the value and re-delivering by hand here would give the window the user
    /// pressed the key in a different path from every other one, which is how two windows end up
    /// disagreeing about the same preference.
    func setQuickViewRenderStyle(_ style: QuickViewRenderStyle) {
        AppPreferences.shared.setQuickViewRenderStyle(style, for: previewedDualStyleKind ?? .page)
    }

    /// Which family of dual-style file is being previewed, or `nil` when it is not one — the file the
    /// two keys and the two menu items mean anything for. Everything else has a single honest
    /// rendering, and a digit there must stay an ordinary keystroke rather than being quietly eaten
    /// by a mode it does not apply to.
    var previewedDualStyleKind: QuickViewDualStyleKind? {
        guard isQuickViewEnabled, let url = focusedPanel.quickViewSourceURL else { return nil }
        return QuickViewPreviewView.dualStyleKind(of: url)
    }

    var previewedFileOffersBothStyles: Bool { previewedDualStyleKind != nil }

    /// The style `url` is drawn in: the remembered choice for its family. A file of neither family
    /// ignores the style, and reads the page choice only so there is one answer to hand over.
    func quickViewRenderStyle(for url: URL?) -> QuickViewRenderStyle {
        let kind = url.flatMap(QuickViewPreviewView.dualStyleKind(of:)) ?? .page
        return AppPreferences.shared.quickViewRenderStyle(for: kind)
    }

    /// Subscribe to `quickViewRenderStyleDidChange`, so a window re-renders the file it is already
    /// showing when the style changes — including the window whose key press changed it. A
    /// selector-based observer, torn down by the blanket `removeObserver(self)` in `deinit`
    /// (docs/NOTES.md: a token-based one cannot be removed from a `nonisolated deinit`).
    func observeQuickViewRenderStyle() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickViewRenderStyleDidChange),
            name: AppPreferences.quickViewRenderStyleDidChange,
            object: nil
        )
    }

    @objc func quickViewRenderStyleDidChange(_ notification: Notification) {
        guard isQuickViewEnabled else { return }
        updateQuickView()
    }
}
