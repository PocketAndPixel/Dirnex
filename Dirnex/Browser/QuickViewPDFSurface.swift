import AppKit
import DirnexCore
import PDFKit

/// The `PDFView` a Quick View PDF preview draws into, with the find bar over it (2026-09-17).
///
/// A view of its own rather than the bare `PDFView` the surface used to pin, for the reason the text
/// and page surfaces are views of their own: the bar takes a strip at the top and the content has to
/// give way to it, which needs something holding both. `QuickViewPreviewView.pdfView` still answers
/// the `PDFView` itself, so everything that zooms, scrolls or reads the document is unchanged.
@MainActor
final class QuickViewPDFSurface: NSView {
    let pdfView = PDFView()

    // Finding in the PDF (`QuickViewPDFSurface+Find`), stored here because an extension cannot.

    /// The bar over the pages, hidden until ⌥⌘F.
    let filterBar: QuickViewTableFilterBar
    /// The matches, the current one and the search in flight (`QuickViewFind`).
    let find = QuickViewFind()
    /// The document's text as one string, read once and kept: `PDFDocument.string` costs 370–420 ms
    /// on a 231-page manual the first time and 1 ms after, so a second search over the same document
    /// is free. Emptied with every new document.
    var documentText = ""
    /// Whether `documentText` has been read for the document on screen.
    var hasReadDocumentText = false
    /// How `documentText` is cut back into pages — `PDFDocument.string` is exactly the pages joined
    /// by one newline, measured on documents of 1, 78 and 231 pages.
    var pageSegments = TextSegmentMap(lengths: [])
    /// The selections currently drawn, so they can be taken off without touching anything else the
    /// view highlights.
    var highlighted: [PDFSelection] = []
    /// The `PDFView`'s top edge: against the surface, or under the bar while it is shown.
    var filterTopToSurface: NSLayoutConstraint?
    var filterTopToBar: NSLayoutConstraint?
    /// Where the keyboard goes when the bar lets go of it: the file list the arrows walk.
    var returnKeyboard: (() -> Void)?

    init(backingColor: NSColor, findOptions: QuickViewFindOptionsStore) {
        filterBar = QuickViewTableFilterBar(findOptions: findOptions)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildPDFView(backingColor: backingColor)
        installFilterBar()
        installFinding()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A new document is on screen: its text is not the one that was read, and the matches were in
    /// the previous document.
    func documentDidChange() {
        documentText = ""
        hasReadDocumentText = false
        pageSegments = TextSegmentMap(lengths: [])
        resetFind()
    }

    /// Continuous single-page layout scrolls a multi-page document naturally, and `PDFView` handles
    /// pinch-to-zoom itself.
    private func buildPDFView(backingColor: NSColor) {
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        // The full-screen surface is deliberately black behind the page; the others follow the
        // window. Reusing the preview's own backing keeps the two consistent for free.
        pdfView.backgroundColor = backingColor
        addSubview(pdfView)
        let top = pdfView.topAnchor.constraint(equalTo: topAnchor)
        filterTopToSurface = top
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            top,
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
