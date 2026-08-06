import AppKit

/// Quick View for the window: the mode where a live preview follows the *active* pane's cursor,
/// at one of three sizes — the inactive pane (⌃Q, PLAN.md §M4), across both panes (⌃⇧Q) or filling
/// the screen (⌃⌥Q, both §M11).
///
/// The window owns the mode because it spans both panes and follows whichever is active — a single
/// pane can't see which that is. The rendering is `QuickViewPreviewView`'s, identical at every
/// size; this decides which surface shows what, and when. Where the two full-size surfaces are
/// anchored, and the native full-screen space they coordinate with, live in
/// `BrowserWindowController+QuickViewFullSize`.
extension BrowserWindowController {
    var isQuickViewEnabled: Bool { quickViewMode != .off }

    /// Everything a window needs before Quick View can be turned on: the two event monitors it
    /// takes keys and swipes with, and the two notifications it follows. One funnel rather than
    /// four lines in `windowDidLoad`, so a fifth piece of Quick View wiring has an obvious home.
    func installQuickViewSupport() {
        installQuickViewKeyMonitor()
        installQuickViewSwipeMonitor()
        observeQuickViewRenderStyle()
        observeQuickViewJavaScript()
        observeQuickViewFullScreen()
    }

    /// ⌃Q / View ▸ Quick View Panel — the *inactive* pane previews the active pane's cursor file.
    @objc func toggleQuickViewPanel(_ sender: Any?) {
        toggleQuickView(.pane)
    }

    /// ⌃⇧Q / View ▸ Quick View Full Window — the preview spans both panes, sidebar and drawer
    /// still in place.
    @objc func toggleQuickViewFullWindow(_ sender: Any?) {
        toggleQuickView(.fullWindow)
    }

    /// ⌃⌥Q / View ▸ Quick View Full Screen — the preview fills the display and the window enters
    /// the native full-screen space.
    @objc func toggleQuickViewFullScreen(_ sender: Any?) {
        toggleQuickView(.fullScreen)
    }

    /// Switch to `mode`, or back to `.off` when it is already showing. A flat toggle per key
    /// rather than an escalation ladder where repeat presses climb — that is a key that never
    /// turns off what it turned on.
    func toggleQuickView(_ mode: QuickViewMode) {
        setQuickViewMode(quickViewMode == mode ? .off : mode)
    }

    /// Close Quick View from any size — Esc's exit, which goes straight out to the file list.
    func closeQuickView() {
        setQuickViewMode(.off)
    }

    func setQuickViewMode(_ mode: QuickViewMode) {
        guard mode != quickViewMode else { return }
        quickViewMode = mode
        // Before the surfaces are reconciled, so the window is already resizing into (or out of)
        // the full-screen space while the preview lays itself out at the size it will land at.
        syncFullScreenSpace(for: mode)
        lockCoveredDividers(for: mode)
        updateQuickView()
        // Keep focus on a real pane. Matters most when closing: Esc may arrive while the preview
        // (a `PDFView` the user clicked into) is first responder, and that view is about to hide.
        focusedPanel.focusTable()
    }

    /// Take the dividers a preview is covering out of service, so a drag across the photograph
    /// cannot silently resize panes behind it (see `LockableDividerSplitViewController`). ⌃⇧Q covers
    /// the panes only — the sidebar and the terminal drawer stay usable, which is what separates it
    /// from full screen; ⌃⌥Q covers the whole content view, so all three are locked.
    private func lockCoveredDividers(for mode: QuickViewMode) {
        panesSplitViewController.isDividerLocked = mode.isFullSize
        paneStackSplitViewController.isDividerLocked = mode == .fullScreen
        splitViewController.isDividerLocked = mode == .fullScreen
    }

    // MARK: - Source or page

    /// View ▸ Quick View ▸ View Source / View Rendered Page, and the `1` / `2` keys behind them.
    @objc func showQuickViewSource(_ sender: Any?) {
        setQuickViewRenderStyle(.source)
    }

    @objc func showQuickViewRenderedPage(_ sender: Any?) {
        setQuickViewRenderStyle(.rendered)
    }

    /// Switch the app-wide style and re-render what is on screen.
    ///
    /// The preference is the single source of truth and every open window follows it, so this
    /// writes it and lets `quickViewRenderStyleDidChange` drive the re-delivery — including this
    /// window's. Setting the value and re-delivering by hand here would give the window the user
    /// pressed the key in a different path from every other one, which is how two windows end up
    /// disagreeing about the same preference.
    private func setQuickViewRenderStyle(_ style: QuickViewRenderStyle) {
        AppPreferences.shared.quickViewRenderStyle = style
    }

    /// Whether the file currently previewed is one the two keys mean anything for. Everything else
    /// has a single honest rendering, and a digit there must stay an ordinary keystroke rather than
    /// being quietly eaten by a mode it does not apply to.
    var previewedFileOffersBothStyles: Bool {
        guard isQuickViewEnabled, let url = focusedPanel.quickViewSourceURL else { return false }
        return QuickViewPreviewView.offersBothStyles(url)
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

    /// Subscribe to `quickViewJavaScriptDidChange`, so a rendered page already on screen is drawn
    /// again under the new answer. Torn down by the blanket `removeObserver(self)` in `deinit`.
    func observeQuickViewJavaScript() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(quickViewJavaScriptDidChange),
            name: AppPreferences.quickViewJavaScriptDidChange,
            object: nil
        )
    }

    /// Reload rather than re-deliver. `show(_:style:)` skips a file it is already showing — which is
    /// right, and is exactly why the style became part of that identity — but the JavaScript answer
    /// is not something the surface holds: it is given per *navigation*. So the page has to be
    /// loaded again, which is what `reloadPage` is for, and every surface gets it because a
    /// background pane's preview must not come back still running (or still missing) the scripts.
    @objc func quickViewJavaScriptDidChange(_ notification: Notification) {
        for surface in [
            leftPanel.quickViewPreview,
            rightPanel.quickViewPreview,
            fullWindowPreview,
            fullScreenPreview
        ] {
            surface?.webSurface?.reloadPage()
        }
        refreshFullSizeCaption()
    }

    /// Re-state the visible full-size header, because the JavaScript mark lives in its caption and
    /// the reload above says nothing about it. Only the caption is touched: re-delivering would ask
    /// the surface to show a file it is already showing, which it rightly skips, and the page has
    /// just been reloaded by the loop above anyway.
    private func refreshFullSizeCaption() {
        guard isQuickViewEnabled, quickViewMode.isFullSize else { return }
        let preview = quickViewMode == .fullScreen ? fullScreenPreview : fullWindowPreview
        guard let preview, !preview.isHidden else { return }
        let active = focusedPanel
        preview.setCaption(quickViewCaption(
            for: active.quickViewSourceURL,
            style: AppPreferences.shared.quickViewRenderStyle,
            from: active
        ))
    }

    func panelCursorDidChange(_ panel: PanelViewController) {
        guard isQuickViewEnabled, panel === focusedPanel else { return }
        showActivePreview(from: panel)
    }

    /// Reconcile every preview surface with the current mode: exactly one of them shows the file
    /// under the active pane's cursor and the rest stand down. Run on every mode change and
    /// whenever the active pane or its cursor changes, so the preview always tracks the focus.
    func updateQuickView() {
        // The panes' own surfaces are only used by `.pane`; the full modes cover them anyway, and
        // leaving one up would put a stale preview behind the new one.
        if quickViewMode != .pane {
            leftPanel.hideQuickViewPreview()
            rightPanel.hideQuickViewPreview()
        }
        if quickViewMode != .fullWindow { standDown(fullWindowPreview) }
        if quickViewMode != .fullScreen { standDown(fullScreenPreview) }
        guard isQuickViewEnabled else { return }
        let active = focusedPanel
        // In pane mode the active pane shows its list and the *other* one previews; in the full
        // modes the preview covers everything, so no pane needs uncovering beyond the above.
        if quickViewMode == .pane { active.hideQuickViewPreview() }
        // A full-size surface flips through *files*: opening one on `..` would show a blank preview
        // with no list beside it to say why, so start on the first file instead. Here rather than in
        // `setQuickViewMode` because switching panes with the preview up arrives the same way.
        if quickViewMode.isFullSize { active.stepOffParentRowForQuickView() }
        showActivePreview(from: active)
    }

    /// Point the current surface at the file under `active`'s cursor. A local file (or an
    /// already-extracted archive member) shows at once; an archive member not yet on disk is
    /// extracted on demand and shown when it lands — provided Quick View is still on and the
    /// cursor hasn't moved on in the meantime.
    private func showActivePreview(from active: PanelViewController) {
        deliverPreview(from: active)
        active.prepareArchivePreview { [weak self, weak active] in
            guard let self, let active, isQuickViewEnabled, active === focusedPanel else { return }
            deliverPreview(from: active)
        }
    }

    /// Load `active`'s cursor file into whichever surface the current mode uses, in the style the
    /// user last chose (PLAN.md §M16). Read here, once per delivery, so every surface a window
    /// drives agrees — and so `1` / `2` need only change the preference and re-deliver.
    private func deliverPreview(from active: PanelViewController) {
        let url = active.quickViewSourceURL
        let style = AppPreferences.shared.quickViewRenderStyle
        switch quickViewMode {
        case .off:
            return
        case .pane:
            counterpart(of: active).showQuickViewPreview(of: url, style: style)
        case .fullWindow:
            present(ensureFullWindowPreview(), url: url, style: style, from: active)
        case .fullScreen:
            present(ensureFullScreenPreview(), url: url, style: style, from: active)
        }
        // The full-size surfaces sit over the *focused* table, so anything a backend does with
        // first responder as it loads would silently turn ↑/↓ into document scrolling — the mode's
        // whole point, lost. Re-assert the table after every show.
        if quickViewMode.isFullSize { restoreTableFocus(to: active) }
    }

    /// Unhide `preview`, load `url` into it, and name the file in its header.
    ///
    /// The header also carries the *style* — but only for a file that genuinely has two, so the
    /// hint appears exactly where `1` / `2` would do something and says nothing everywhere else.
    private func present(
        _ preview: QuickViewPreviewView,
        url: URL?,
        style: QuickViewRenderStyle,
        from active: PanelViewController
    ) {
        preview.isHidden = false
        preview.show(url, style: style)
        preview.setCaption(quickViewCaption(for: url, style: style, from: active))
    }

    /// `active`'s own caption, plus the two things only the window knows: the style the file is
    /// being shown in, and whether that rendering ran the page's scripts. Both are stated only for
    /// a file that genuinely has two styles, so the hint appears exactly where `1` / `2` would do
    /// something and says nothing everywhere else.
    ///
    /// The two are *not* the same question, which is why the mark has its own test rather than
    /// riding on `offersBothStyles`. A Markdown preview is a page **we** generated, with the file's
    /// raw HTML escaped (PLAN.md §M18) — so there is no script in it to have refused, and
    /// "(no JavaScript)" would be true and meaningless. Same argument that already keeps the mark
    /// out of source mode.
    private func quickViewCaption(
        for url: URL?,
        style: QuickViewRenderStyle,
        from active: PanelViewController
    ) -> QuickViewCaption? {
        var caption = active.quickViewCaption
        guard let url, QuickViewPreviewView.offersBothStyles(url) else {
            caption?.style = nil
            return caption
        }
        caption?.style = style
        caption?.javaScriptDisabled = !AppPreferences.shared.quickViewJavaScriptEnabled
            && QuickViewPreviewView.isRenderableHTML(url)
        return caption
    }

    /// Hide a full-size surface and release what it had loaded. A no-op for one never built.
    private func standDown(_ preview: QuickViewPreviewView?) {
        guard let preview, !preview.isHidden else { return }
        preview.isHidden = true
        preview.clear()
    }

    /// Hand first responder back to `panel`'s file table unless it already has it — an
    /// unconditional `makeFirstResponder` on every cursor step is churn the table doesn't need.
    private func restoreTableFocus(to panel: PanelViewController) {
        guard window?.firstResponder !== panel.tableView else { return }
        panel.focusTable()
    }

    /// The two keys Quick View has to take back from the window while a preview is up: **Esc**,
    /// which closes the mode from anywhere, and a bare **arrow**, which walks the file list.
    ///
    /// One window-scoped local monitor for both, because a monitor sees the raw key *ahead of
    /// responder dispatch* and that is the only place either can be caught. The in-process backends
    /// take first responder the moment the user clicks into one — the text view to select a line,
    /// `PDFView` to scroll a document — and from there a focused `PDFView` may never translate Esc
    /// into `cancelOperation:`, while both of them consume the arrows as caret movement or
    /// scrolling. Only fires while this window is key, so a sheet, the ⌘K palette, or the Settings
    /// window keep their own keys. Installed once from `init`; torn down in `deinit`.
    func installQuickViewKeyMonitor() {
        quickViewKeyMonitor = NSEvent
            .addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
                      window?.isKeyWindow == true,
                      isQuickViewEnabled
                else { return event }
                switch event.keyCode {
                case 53: // Esc
                    guard escapeBelongsToQuickView else { return event }
                    closeQuickView()
                    return nil
                case 123, 124, 125, 126: // ← → ↓ ↑
                    reclaimArrowsFromPreview()
                    return event
                default:
                    // 1 / 2 — the render style, by character rather than key code so a non-US
                    // layout and the keypad both work (docs/NOTES.md).
                    guard let digit = event.charactersIgnoringModifiers,
                          let style = QuickViewRenderStyle.style(forDigit: digit),
                          digitBelongsToQuickView
                    else { return event }
                    setQuickViewRenderStyle(style)
                    return nil
                }
            }
    }

    /// Whether Esc means "close Quick View" here, or belongs to whatever holds focus. A file table
    /// runs its own progressive Esc (clear filter → close Quick View → clear marks) through
    /// `fileTableCancel`, and a field editor cancels the edit it is in — the preview's own text view
    /// being the exception among `NSText`s, since it takes focus when the user clicks in to select
    /// something and Esc there means "out of the preview", exactly as it does with the pointer
    /// anywhere else on the surface. The terminal drawer owns Esc far more so: it is `vim`'s entire
    /// modal interface, and a monitor that swallowed it to close a preview would make the drawer
    /// useless for the editor most likely to be running in it.
    private var escapeBelongsToQuickView: Bool {
        let responder = window?.firstResponder
        if responder is FileTableView { return false }
        if responder is NSText, !(responder is QuickViewDocumentTextView) { return false }
        return !isTerminalFocused
    }

    /// Whether `1` / `2` mean "switch the rendering" here, or are an ordinary digit somebody is
    /// typing (PLAN.md §M16).
    ///
    /// It has to be asked, and it is not the same question as Esc's. Found live: with a preview up,
    /// ⌘L and typing `/tmp/12` put **`/tmp/`** in the path field — the monitor ate both digits, in a
    /// text field, with the caret visibly in it. The two branches sit three lines apart in the same
    /// monitor, and a branch added beside an existing one inherits *none* of its carve-outs; Esc's
    /// were written into `escapeBelongsToQuickView` rather than into the monitor, which is what made
    /// the omission invisible at the call site.
    ///
    /// Three exemptions, and only the first is shared with Esc verbatim. A **field editor** owns
    /// every character typed into it — a rename, the path bar, the filter — with the preview's own
    /// text view the exception, since a digit there is not being typed *anywhere*. The **terminal
    /// drawer** owns its keys outright. And unlike Esc there is no `FileTableView` exemption: the
    /// table is exactly where these keys are meant to work.
    private var digitBelongsToQuickView: Bool {
        let responder = window?.firstResponder
        if responder is NSText, !(responder is QuickViewDocumentTextView) { return false }
        return !isTerminalFocused && previewedFileOffersBothStyles
    }

    /// Hand the arrows back to the file list once the user has clicked into a preview.
    ///
    /// Selecting a line of a text preview (or clicking into a PDF) makes that backend first
    /// responder, and it then eats ← / → — and ↑ / ↓, which mean the same thing while a full-size
    /// preview covers the list — as caret movement or document scrolling. The two-finger swipe never
    /// lost the mode for the two reasons it works at all: it is a window monitor, and every flip
    /// re-asserts the table (`restoreTableFocus`). This is the keyboard's half of exactly that.
    ///
    /// Focus goes to the **focused** pane's table — the one whose list is being walked, which in
    /// pane mode is not the pane the preview covers — and the key is then left to travel rather than
    /// swallowed. Probed: a local monitor runs before responder dispatch, so this very event lands
    /// on the table set here. So the table's own `keyDown` stays the single definition of what an
    /// arrow does (a flip at full size, a plain cursor step in pane mode) instead of this monitor
    /// carrying a second copy of it.
    ///
    /// Bare arrows only, per the modifier guard above: ⇧← still extends the selection in the text
    /// the user is in the middle of selecting.
    private func reclaimArrowsFromPreview() {
        let surfaces = [
            leftPanel.quickViewPreview,
            rightPanel.quickViewPreview,
            fullWindowPreview,
            fullScreenPreview
        ]
        guard QuickViewPreviewView.hasFocus(window?.firstResponder, among: surfaces) else { return }
        focusedPanel.focusTable()
    }
}
