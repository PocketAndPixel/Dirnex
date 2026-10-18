import AppKit

/// Which in-process backend is on this surface, for the keys that drive one from outside it: ⌘+ / ⌘−
/// (`QuickViewPreviewView+Zoom`) and the ⇧-arrows (`QuickViewPreviewView+Scroll`). One list for both,
/// so a backend added for one cannot be forgotten by the other.
///
/// Quick Look's out-of-process view and the remote placeholder card are not on it: neither has
/// anything a key from outside can zoom or scroll.
extension QuickViewPreviewView {
    enum ContentTarget {
        case web(QuickViewWebView)
        case pdf(QuickViewPDFSurface)
        case text(QuickViewTextView)
        case image(QuickViewImageScrollView)
        case table(QuickViewTableView)
        case tree(QuickViewTreeView)
    }

    /// The backend on screen, if it is one of those. Moved out of the zoom code when scrolling joined
    /// it (2026-10-18), unchanged.
    var contentTarget: ContentTarget? {
        if placeholderCard?.isHidden == false { return nil }
        if let tableSurface, !tableSurface.isHidden, tableSurface.table != nil {
            return .table(tableSurface)
        }
        if let treeSurface, !treeSurface.isHidden, treeSurface.document != nil {
            return .tree(treeSurface)
        }
        if let webSurface, !webSurface.isHidden { return .web(webSurface) }
        if let pdfSurface, !pdfSurface.isHidden, pdfSurface.pdfView.document != nil {
            return .pdf(pdfSurface)
        }
        if let textSurface, !textSurface.isHidden { return .text(textSurface) }
        if let imageScrollView, !imageScrollView.isHidden, imageScrollView.imageView.image != nil {
            return .image(imageScrollView)
        }
        return nil
    }
}
