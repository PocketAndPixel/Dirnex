import AppKit

/// Quick View (⌃Q) for the window: the mode where the *inactive* pane shows a live Quick Look
/// preview of whatever the *active* pane's cursor is on (PLAN.md §M4 "Quick View panel").
///
/// The window owns the mode because it spans both panes and follows whichever is active — a single
/// pane can't see which that is. The rendering of a preview is the pane's own
/// (`PanelViewController+QuickView`); this only decides which pane shows what, and when.
extension BrowserWindowController {
    var isQuickViewEnabled: Bool { isQuickViewOn }

    func toggleQuickView() {
        isQuickViewOn.toggle()
        updateQuickView()
        // Keep focus on a real pane. Matters most when closing: Esc may arrive while the preview
        // (a `PDFView` the user clicked into) is first responder, and that view is about to hide.
        focusedPanel.focusTable()
    }

    func panelCursorDidChange(_ panel: PanelViewController) {
        guard isQuickViewOn, panel === focusedPanel else { return }
        showActivePreview(from: panel)
    }

    /// Reconcile both panes with the current Quick View state: the active pane shows its file
    /// list, the inactive pane previews the file under the active cursor. With the mode off,
    /// both panes drop any preview. Run on every toggle and whenever the active pane changes,
    /// so the preview always sits opposite the focused pane.
    func updateQuickView() {
        guard isQuickViewOn else {
            leftPanel.hideQuickViewPreview()
            rightPanel.hideQuickViewPreview()
            return
        }
        let active = focusedPanel
        active.hideQuickViewPreview()
        showActivePreview(from: active)
    }

    /// Point the inactive pane's preview at the file under `active`'s cursor. A local file (or an
    /// already-extracted archive member) shows at once; an archive member not yet on disk is
    /// extracted on demand and shown when it lands — provided Quick View is still on and the
    /// cursor hasn't moved on in the meantime.
    private func showActivePreview(from active: PanelViewController) {
        counterpart(of: active).showQuickViewPreview(of: active.quickViewSourceURL)
        active.prepareArchivePreview { [weak self, weak active] in
            guard let self, let active, isQuickViewOn, active === focusedPanel else { return }
            counterpart(of: active).showQuickViewPreview(of: active.quickViewSourceURL)
        }
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
                  isQuickViewOn
            else { return event }
            let responder = window?.firstResponder
            // A file table or a text edit owns Esc for its own purpose — let the event through.
            if responder is FileTableView || responder is NSText { return event }
            // So does the terminal drawer, far more so: Esc is `vim`'s entire modal interface, and
            // a monitor that swallowed it to close a preview would make the drawer useless for the
            // editor most likely to be running in it.
            if isTerminalFocused { return event }
            toggleQuickView()
            return nil
        }
    }
}
