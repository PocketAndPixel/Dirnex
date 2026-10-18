import AppKit
import DirnexCore

/// ⇧↑ / ⇧↓, ⇧Page Up / ⇧Page Down and ⇧← / ⇧→ on a Quick View preview (2026-10-18): how a move reaches
/// the backend on screen. The keys are caught by the file table (`BrowserWindowController+QuickViewScroll`
/// says why), so the list keeps the focus and the next plain arrow walks on to the next file.
///
/// Every backend but one scrolls the same way, through its own scroll view's clip view: text, a PDF, a
/// CSV table, a JSON or XML tree and a zoomed image. A rendered page scrolls inside WebKit and is
/// reached with a script (`QuickViewWebView+Scroll`). Quick Look's own view draws in another process
/// and offers no way to scroll it, so the keys do nothing over a movie or a font, as they do over the
/// remote placeholder card.
extension QuickViewPreviewView {
    func scrollContent(_ move: QuickViewScroll) {
        switch contentTarget {
        case let .web(surface): surface.scrollPage(move)
        case let .pdf(surface): surface.scrollDocument(move)
        case let .text(surface): surface.scrollView.scrollDocument(move)
        case let .image(scrollView): scrollView.scrollDocument(move)
        case let .table(surface): surface.scrollView.scrollDocument(move)
        case let .tree(surface): surface.scrollView.scrollDocument(move)
        case nil: break
        }
    }
}

extension QuickViewPDFSurface {
    /// Scroll the document, then redraw the find's highlights for the pages that came into view, which
    /// `PDFView` does not announce for a move of its clip view (`visiblePagesDidMove`).
    func scrollDocument(_ move: QuickViewScroll) {
        pdfView.documentView?.enclosingScrollView?.scrollDocument(move)
        visiblePagesDidMove()
    }
}

extension NSScrollView {
    /// Move the document `move`'s distance, in the document's own units, stopping at its edges.
    ///
    /// The edges are the **clip view's**: the move is proposed and `constrainBoundsRect` decides where
    /// it may land, so the top is wherever AppKit would rest the view rather than an origin worked out
    /// here. That matters for a table, whose header floats over its rows — measured, its resting origin
    /// is 60 points *above* the document in a full-size-content window (the header and the title bar),
    /// and an origin of 0 hides the first row (docs/NOTES.md ▸ Tables). An image smaller than its view
    /// stays centered the same way, through its own clip view's rule. Measured too, in TextKit 2: the
    /// clamp reaches the last character of a 13 MB text exactly, as `scrollToEndOfDocument` does.
    ///
    /// A page is measured over the document the reader can **see**, which is not the clip view's height:
    /// whatever floats over the clip — that header, a title bar — hides part of it the whole time. The
    /// clip view rests beyond the document's edges by exactly those amounts, so what is seen is the
    /// document's height less the distance between the two resting origins. Paged by the clip's own
    /// height, the table above would skip 20 points of rows at every press, the header and title bar
    /// covering more than a line step's overlap.
    func scrollDocument(_ move: QuickViewScroll) {
        guard let document = documentView else { return }
        let clip = contentView
        var bounds = clip.bounds
        // Toward the end is down the screen, which is +y in a flipped document and −y in one that is
        // not: a PDF's, measured.
        let down: CGFloat = document.isFlipped ? 1 : -1
        let start = restingOrigin(down: -down, document: document)
        let end = restingOrigin(down: down, document: document)
        let seen = document.frame.height - abs(end - start)
        bounds.origin.y = switch move.travel(visibleHeight: seen) {
        case let .by(distance): bounds.origin.y + down * distance
        case .toStart: start
        case .toEnd: end
        }
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        reflectScrolledClipView(clip)
    }

    /// Where the clip view comes to rest when pushed past the document's edge along `down` (+1 up the
    /// y axis, −1 down it), by its own clamp.
    private func restingOrigin(down: CGFloat, document: NSView) -> CGFloat {
        var far = contentView.bounds
        far.origin.y += down * (document.frame.height + far.height)
        return contentView.constrainBoundsRect(far).origin.y
    }
}
