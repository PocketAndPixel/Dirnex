import AppKit
import DirnexCore

/// ⌘+, ⌘− and ⌘0 on a Quick View preview (2026-09-14): which backend on this surface can zoom, and
/// how a step reaches it. The keys themselves are the window's (`BrowserWindowController+QuickViewZoom`),
/// since the surface refuses first responder so the arrows keep driving the file list.
///
/// Seven backends zoom and two do not. A web page (HTML, Markdown, a converted office document), a PDF
/// (including a converted iWork document) and text (source or rich) each already had a zoom a pinch
/// could reach, and the keys drive that same zoom; an image gained one of its own
/// (`QuickViewImageScrollView`), and so did the CSV table and the JSON tree, which scale what they are
/// drawn with. Quick Look's out-of-process view and the remote placeholder card have nothing to zoom,
/// so the commands are disabled there.
extension QuickViewPreviewView {
    /// The zooming backend on screen, if any.
    private enum ZoomTarget {
        case web(QuickViewWebView)
        case pdf
        case text(QuickViewTextView)
        case image(QuickViewImageScrollView)
        case table(QuickViewTableView)
        case tree(QuickViewTreeView)
    }

    private var zoomTarget: ZoomTarget? {
        if placeholderCard?.isHidden == false { return nil }
        if let tableSurface, !tableSurface.isHidden, tableSurface.table != nil {
            return .table(tableSurface)
        }
        if let treeSurface, !treeSurface.isHidden, treeSurface.document != nil {
            return .tree(treeSurface)
        }
        if let webSurface, !webSurface.isHidden { return .web(webSurface) }
        if let pdfView, !pdfView.isHidden, pdfView.document != nil { return .pdf }
        if let textSurface, !textSurface.isHidden { return .text(textSurface) }
        if let imageScrollView, !imageScrollView.isHidden, imageScrollView.imageView.image != nil {
            return .image(imageScrollView)
        }
        return nil
    }

    /// The current level relative to how the file opened, or `nil` when nothing on screen zooms.
    private var zoomLevel: Double? {
        switch zoomTarget {
        case let .web(surface): surface.zoomLevel
        case .pdf: pdfZoomLevel
        case let .text(surface): surface.zoomLevel
        case let .image(scrollView): scrollView.zoomLevel
        case let .table(surface): surface.zoomLevel
        case let .tree(surface): surface.zoomLevel
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
        case let .image(scrollView): !scrollView.isAtStartingZoom
        case let .table(surface): !surface.isAtStartingZoom
        case let .tree(surface): !surface.isAtStartingZoom
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
        case let .image(scrollView): scrollView.resetZoom()
        case let .table(surface): surface.setZoomLevel(1)
        case let .tree(surface): surface.setZoomLevel(1)
        case nil: break
        }
    }

    private func apply(_ level: Double) {
        switch zoomTarget {
        case let .web(surface): surface.setZoomLevel(level)
        case .pdf: setPDFZoomLevel(level)
        case let .text(surface): surface.setZoomLevel(level)
        case let .image(scrollView): scrollView.setZoomLevel(level)
        case let .table(surface): surface.setZoomLevel(level)
        case let .tree(surface): surface.setZoomLevel(level)
        case nil: break
        }
    }

    /// Whether the content on screen is zoomed wider than the surface, so a sideways two-finger scroll
    /// belongs to it — panning — rather than to the swipe that turns to the next file. Preview's own
    /// rule: the swipe only flips pages that fit.
    ///
    /// An image and a PDF can say so, and so can a table or a tree, which are often wider than the
    /// surface as they open. Text never runs wider than the surface (it re-wraps as it zooms), and a
    /// web page scrolls inside WebKit, where the width is not ours to read without a script — so a
    /// page keeps the swipe it always had.
    var consumesHorizontalScroll: Bool {
        if let tableSurface, !tableSurface.isHidden { return tableSurface.pansHorizontally }
        if let treeSurface, !treeSurface.isHidden { return treeSurface.pansHorizontally }
        return switch zoomTarget {
        case let .image(scrollView): scrollView.pansHorizontally
        case .pdf:
            if let scrollView = pdfView?.documentView?.enclosingScrollView,
               let document = scrollView.documentView {
                document.frame.width > scrollView.contentView.bounds.width + 0.5
            } else {
                false
            }
        case .web, .text, .table, .tree, nil: false
        }
    }
}
