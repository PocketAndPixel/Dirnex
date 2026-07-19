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
}
