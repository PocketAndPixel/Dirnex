import AppKit
import DirnexCore
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// The embedded Quick View panel (PLAN.md §M4 "Quick view panel"): TC's ⌃Q mode where the
/// *inactive* pane stops showing its file list and instead becomes a live Quick Look preview
/// of the file under the *active* pane's cursor. Distinct from ⌘Y Quick Look, which floats a
/// separate window over the active pane; this replaces the opposite pane in place.
///
/// The window (`BrowserWindowController`) owns the on/off state and decides which pane hosts
/// the preview, since the mode spans both panes and follows the active one. A pane only knows
/// how to (a) surface a preview over its own list and (b) report the file under its cursor.
///
/// Two preview backends share the overlay: `QLPreviewView` for the general case and `PDFView`
/// for PDFs, because Quick Look only wires up zoom for single-page PDFs — a multi-page document
/// can't be magnified through it. PDFKit zooms and scrolls every PDF, so PDFs route there.
extension PanelViewController {
    /// ⌃Q / View ▸ Quick View Panel — hand the toggle to the window, which flips the mode and
    /// reconciles both panes.
    @objc func toggleQuickViewPanel(_ sender: Any?) {
        host?.toggleQuickView()
    }

    /// Cover this pane's file list with a live preview of `url` (the file under the *other*
    /// pane's cursor). Lazily builds the overlay on first use and routes to the backend that
    /// fits the file — `PDFView` for PDFs, `QLPreviewView` otherwise. `nil` clears it to a blank
    /// preview — the cursor is on `..` or an empty directory, so there is nothing to show.
    func showQuickViewPreview(of url: URL?) {
        ensureQuickViewContainer().isHidden = false
        guard url != quickViewLoadedURL else { return }
        quickViewLoadedURL = url
        if let url, isPDF(url) {
            showPDFPreview(of: url)
        } else {
            showQuickLookPreview(of: url)
        }
    }

    /// Uncover the file list, restoring the normal pane. Safe to call when Quick View was
    /// never shown for this pane. Releases both backends' loaded documents so nothing lingers
    /// in memory while the mode is off.
    func hideQuickViewPreview() {
        quickViewLoadedURL = nil
        quickViewContainer?.isHidden = true
        quickViewPreview?.previewItem = nil
        quickViewPDFView?.document = nil
    }

    /// The file under this pane's cursor as a URL, for the *other* pane to preview — `nil` on
    /// the `..` row or in an empty directory. A local entry resolves at once; an archive member
    /// resolves to its extracted temp file once cached (nil until `prepareArchivePreview` lands
    /// it), so the window re-drives the preview when the extraction finishes.
    var quickViewSourceURL: URL? {
        guard !cursorOnParentRow, let entry = panel.currentEntry else { return nil }
        if entry.path.backend == .local { return entry.path.localURL }
        guard let member = previewableArchiveMember else { return nil }
        return host?.archivePreviewCache.cachedURL(for: member)
    }

    // MARK: - Backends

    /// Show `url` in the Quick Look backend, standing down the PDF one.
    private func showQuickLookPreview(of url: URL?) {
        guard let preview = ensureQuickLookPreview() else { return }
        quickViewPDFView?.isHidden = true
        quickViewPDFView?.document = nil
        preview.isHidden = false
        preview.previewItem = url as NSURL?
    }

    /// Show `url` in the PDFKit backend, standing down the Quick Look one. `autoScales` refits
    /// the page to the pane for each new document; the user can then pinch to zoom in or out.
    private func showPDFPreview(of url: URL) {
        let pdfView = ensurePDFView()
        quickViewPreview?.isHidden = true
        quickViewPreview?.previewItem = nil
        pdfView.isHidden = false
        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
    }

    /// Whether `url` is a PDF, so it routes to `PDFView`. Prefers the file's real content type
    /// (catches an odd extension) and falls back to the extension when that can't be read.
    private func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
    }

    // MARK: - Lazy view construction

    /// Build the opaque overlay on first use and pin it over the scroll view. The list under it
    /// stays laid out (only covered), so uncovering it needs no relayout. The `NSBox` is filled
    /// with the dynamic `textBackgroundColor` so a preview that doesn't fill the pane (a small
    /// image, a failed preview) can't let the table bleed through, and so the backing re-resolves
    /// its color on a light/dark switch (a captured `cgColor` would not). Both backends are
    /// pinned inside its content view; only the one in use is unhidden.
    private func ensureQuickViewContainer() -> NSView {
        if let container = quickViewContainer { return container }
        let container = NSBox()
        container.boxType = .custom
        container.titlePosition = .noTitle
        container.borderWidth = 0
        container.cornerRadius = 0
        container.contentViewMargins = .zero
        container.fillColor = .textBackgroundColor
        container.contentView = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            container.topAnchor.constraint(equalTo: scrollView.topAnchor),
            container.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor)
        ])
        quickViewContainer = container
        return container
    }

    /// Build the Quick Look backend on first use. `.compact` style drops Quick Look's
    /// title/controls chrome, which suits an always-on embedded pane. `init(frame:style:)` is
    /// failable, so this returns `nil` on the rare miss and the caller shows nothing.
    private func ensureQuickLookPreview() -> QLPreviewView? {
        if let preview = quickViewPreview { return preview }
        guard let preview = QLPreviewView(frame: .zero, style: .compact) else { return nil }
        // Closes automatically when the window goes away; the pane lives as long as the window,
        // so there is nothing to tear down by hand.
        preview.shouldCloseWithWindow = true
        pinInsideQuickViewContainer(preview)
        quickViewPreview = preview
        return preview
    }

    /// Build the PDFKit backend on first use. Continuous single-page layout scrolls a multi-page
    /// document naturally, and `PDFView` handles pinch-to-zoom itself.
    private func ensurePDFView() -> PDFView {
        if let pdfView = quickViewPDFView { return pdfView }
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pinInsideQuickViewContainer(pdfView)
        quickViewPDFView = pdfView
        return pdfView
    }

    /// Pin `subview` edge to edge inside the overlay's content view, so both backends fill the
    /// pane and stack in the same place.
    private func pinInsideQuickViewContainer(_ subview: NSView) {
        guard let content = (ensureQuickViewContainer() as? NSBox)?.contentView else { return }
        subview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            subview.topAnchor.constraint(equalTo: content.topAnchor),
            subview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }
}
