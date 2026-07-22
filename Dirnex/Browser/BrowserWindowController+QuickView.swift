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
        updateQuickView()
        // Keep focus on a real pane. Matters most when closing: Esc may arrive while the preview
        // (a `PDFView` the user clicked into) is first responder, and that view is about to hide.
        focusedPanel.focusTable()
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

    /// Load `active`'s cursor file into whichever surface the current mode uses.
    private func deliverPreview(from active: PanelViewController) {
        let url = active.quickViewSourceURL
        switch quickViewMode {
        case .off:
            return
        case .pane:
            counterpart(of: active).showQuickViewPreview(of: url)
        case .fullWindow:
            present(ensureFullWindowPreview(), url: url, from: active)
        case .fullScreen:
            present(ensureFullScreenPreview(), url: url, from: active)
        }
        // The full-size surfaces sit over the *focused* table, so anything a backend does with
        // first responder as it loads would silently turn ↑/↓ into document scrolling — the mode's
        // whole point, lost. Re-assert the table after every show.
        if quickViewMode.isFullSize { restoreTableFocus(to: active) }
    }

    /// Unhide `preview`, load `url` into it, and name the file in its header.
    private func present(
        _ preview: QuickViewPreviewView,
        url: URL?,
        from active: PanelViewController
    ) {
        preview.isHidden = false
        preview.show(url)
        preview.setCaption(active.quickViewCaption)
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

    /// Esc closes Quick View from anywhere in this window. A window-scoped local monitor sees the
    /// raw key event ahead of responder dispatch, so it works even when the focused view (the
    /// preview `PDFView`) would otherwise swallow the key. It deliberately stands aside for the
    /// responders that own Esc themselves: a focused file table runs its progressive Esc (clear
    /// filter → close Quick View → clear marks) via `fileTableCancel`, and a text field editor
    /// cancels the edit. Only fires while this window is key, so a sheet, the ⌘K palette, or the
    /// Settings window keep their own Esc. Installed once from `init`; torn down in `deinit`.
    func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.keyCode == 53, // Esc
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]),
                  window?.isKeyWindow == true,
                  isQuickViewEnabled
            else { return event }
            let responder = window?.firstResponder
            // A file table or a text edit owns Esc for its own purpose — let the event through.
            if responder is FileTableView || responder is NSText { return event }
            // So does the terminal drawer, far more so: Esc is `vim`'s entire modal interface, and
            // a monitor that swallowed it to close a preview would make the drawer useless for the
            // editor most likely to be running in it.
            if isTerminalFocused { return event }
            closeQuickView()
            return nil
        }
    }
}
