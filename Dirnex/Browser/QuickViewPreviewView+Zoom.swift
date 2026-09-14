import AppKit
import DirnexCore

/// ⌘+, ⌘− and ⌘0 on a Quick View preview (2026-09-14): which backend on this surface can zoom, and
/// how a step reaches it. The keys themselves are the window's (`BrowserWindowController+QuickViewZoom`),
/// since the surface refuses first responder so the arrows keep driving the file list.
///
/// Three backends zoom and three do not, and the split is not arbitrary. A web page (HTML, Markdown,
/// a converted office document), a PDF (including a converted iWork document) and text (source or
/// rich) each already had a zoom a pinch could reach, and the keys drive that same zoom. A photograph,
/// Quick Look's own out-of-process view and the remote placeholder card have none — the image view
/// fits a photo to the surface with no scroll view to pan a larger one in — so the commands are
/// disabled there rather than doing something the pinch cannot.
extension QuickViewPreviewView {
    /// The zooming backend on screen, if any.
    private enum ZoomTarget {
        case web(QuickViewWebView)
        case pdf
        case text(QuickViewTextView)
    }

    private var zoomTarget: ZoomTarget? {
        if placeholderCard?.isHidden == false { return nil }
        if let webSurface, !webSurface.isHidden { return .web(webSurface) }
        if let pdfView, !pdfView.isHidden, pdfView.document != nil { return .pdf }
        if let textSurface, !textSurface.isHidden { return .text(textSurface) }
        return nil
    }

    /// The current level relative to how the file opened, or `nil` when nothing on screen zooms.
    private var zoomLevel: Double? {
        switch zoomTarget {
        case let .web(surface): surface.zoomLevel
        case .pdf: pdfZoomLevel
        case let .text(surface): surface.zoomLevel
        case nil: nil
        }
    }

    /// Whether a step `direction` would do anything — the menu item's enabled state.
    func canZoom(_ direction: QuickViewZoom.Direction) -> Bool {
        guard let zoomLevel else { return false }
        return QuickViewZoom.step(from: zoomLevel, direction) != nil
    }

    /// Whether ⌘0 would change anything: something zooms, and it is not already as it opened.
    var canResetZoom: Bool {
        switch zoomTarget {
        case let .web(surface): !surface.isAtStartingZoom
        case .pdf: abs(pdfZoomLevel - 1) > 0.005 || pdfView?.autoScales != pdfFitsWidth
        case let .text(surface): abs(surface.zoomLevel - 1) > 0.005
        case nil: false
        }
    }

    /// One step along the ladder. Does nothing at its end or when nothing on screen zooms.
    func zoom(_ direction: QuickViewZoom.Direction) {
        guard let zoomLevel, let next = QuickViewZoom.step(from: zoomLevel, direction) else { return }
        apply(next)
    }

    /// Back to how the file opened.
    func resetZoom() {
        switch zoomTarget {
        case let .web(surface): surface.resetZoom()
        case .pdf: setPDFZoomLevel(1)
        case let .text(surface): surface.setZoomLevel(1)
        case nil: break
        }
    }

    private func apply(_ level: Double) {
        switch zoomTarget {
        case let .web(surface): surface.setZoomLevel(level)
        case .pdf: setPDFZoomLevel(level)
        case let .text(surface): surface.setZoomLevel(level)
        case nil: break
        }
    }
}
