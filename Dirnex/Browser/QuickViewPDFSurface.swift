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
    /// The document's text, page by page — the pages that carry their own, and the scanned ones as
    /// they are read (``DirnexCore/PagedDocumentText``). Read once per document and kept: the text
    /// layer costs 370–420 ms on a 231-page manual the first time and 1 ms after, and a page that
    /// has to be recognized costs ~0.2–0.5 s and is never read twice.
    var pages = PagedDocumentText(layerText: [])
    /// Whether the document on screen has had its text layer read.
    var hasReadPages = false
    /// What reads a scanned page. Injected so the reading — a page at a time, searching as they
    /// land, stopping when nobody is waiting — can be tested without Vision and without a scanned
    /// fixture in the repo.
    let recognizer: PDFPageTextRecognizing
    /// The reading in flight, and what stops one the reader has moved past.
    var recognitionTask: Task<Void, Never>?
    /// Bumped by every new document, so a page landing for the previous one is discarded.
    var recognitionGeneration = 0
    /// The selections currently drawn, so they can be taken off without touching anything else the
    /// view highlights.
    var highlighted: [PDFSelection] = []
    /// The highlights drawn on recognized pages, which have no selection to be made of them, with
    /// the page each was put on so it can be taken off again.
    var recognizedHighlights: [(page: PDFPage, annotation: PDFAnnotation)] = []
    /// The `PDFView`'s top edge: against the surface, or under the bar while it is shown.
    var filterTopToSurface: NSLayoutConstraint?
    var filterTopToBar: NSLayoutConstraint?
    /// Where the keyboard goes when the bar lets go of it: the file list the arrows walk.
    var returnKeyboard: (() -> Void)?

    /// `recognizer` defaults to the shared one, which is also where what it has read is kept — a
    /// store in memory and nowhere else (``VisionPageTextRecognizer``). A default rather than a
    /// required argument, unlike `tabStateDefaults` and the undo journal's domain, because nothing
    /// here is written outside the process: a test that does not care cannot leak into anything,
    /// and a test that does hands over a fake.
    init(
        backingColor: NSColor,
        findOptions: QuickViewFindOptionsStore,
        recognizer: PDFPageTextRecognizing = VisionPageTextRecognizer.shared
    ) {
        filterBar = QuickViewTableFilterBar(findOptions: findOptions)
        self.recognizer = recognizer
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
        recognitionGeneration += 1
        recognitionTask = nil
        pages = PagedDocumentText(layerText: [])
        hasReadPages = false
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
