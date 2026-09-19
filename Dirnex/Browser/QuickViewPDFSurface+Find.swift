import AppKit
import DirnexCore
import PDFKit

/// Finding text in Quick View's PDF preview, which is also every Pages, Numbers and Keynote document
/// (`QuickViewPreviewView+Document` merges those into one PDF) — 2026-09-18, reading scanned pages
/// since 2026-09-19.
///
/// The bar and its keys are the table's (`QuickViewFilterHost`), and the state machine is the one
/// every finding surface runs (`QuickViewFindHost`). What is this surface's own:
///
/// **What the text is.** Each page's own text layer, read once off the main actor and kept — 370–420
/// ms for a 231-page manual the first time and 1 ms afterwards, measured, and measured safe to read
/// on a background thread while the main thread lays the same document out. A page with **no** text
/// layer has to be recognized before it has any, which is `QuickViewPDFSurface+Recognize`. Matching
/// is `DirnexCore`'s (``DirnexCore/TextFindMatches``) rather than `PDFDocument.findString`, which is
/// faster and does not agree with it: probed, PDFKit folds ß against ss, matches a ﬁ ligature
/// against `fi`, and finds a Kelvin sign for `k`, where every other Quick View surface matches the
/// way the table and tree filters do. A find bar that counted differently depending on which preview
/// was up would be the same bar telling two stories.
///
/// **How a match is found again on a page.** The pages are joined by one newline — which is exactly
/// what `PDFDocument.string` is, verified on documents of 1, 78 and 231 pages — so
/// ``DirnexCore/PagedDocumentText`` turns an offset into the page holding it and into whatever that
/// page can be drawn with. A match running across a page break becomes a mark on each page rather
/// than being dropped.
///
/// **How a match is drawn.** A page with a text layer gets a `PDFSelection`, the current match in
/// orange and the rest in the find yellow. A recognized page has no selection to be made of it —
/// `PDFPage.selection(for:)` there does not fail, it answers a selection whose bounds are
/// `(inf, inf, 0, 0)` and whose string is `nil`, measured, which draws nothing and reports nothing —
/// so it gets a highlight annotation over each word instead. Only the matches on the pages nearby
/// carry either: assigning 20 000 selections costs 88 ms and building 58 000 costs 48 ms, which is a
/// price per keystroke rather than per document, and `PDFView.visiblePages` makes "nearby" exact.
extension QuickViewPDFSurface: QuickViewFindHost {
    var filterContentView: NSView { pdfView }

    var hasFilterableContent: Bool { pdfView.document != nil }

    var keyboardFallback: NSView { pdfView }

    /// What is still being read, for the count line — `nil` once there is nothing left to read, so
    /// an ordinary PDF never mentions it.
    var findReadingProgress: (read: Int, total: Int)? {
        guard pages.needsReading, !pages.isComplete else { return nil }
        return (pages.readCount, pages.unreadPageCount)
    }

    /// The document's text: every page's own, and the scanned pages that have been read so far.
    ///
    /// Reading the text layer is off the main actor, where it belongs — nearly half a second on a
    /// long manual is not a keystroke's worth of main-thread time — and asking for the text is also
    /// what starts the scanned pages being read, because a search is the only thing that makes
    /// reading them worth a minute of somebody's machine.
    func findableText() async -> String {
        guard let document = pdfView.document else { return "" }
        if !hasReadPages {
            let box = PDFDocumentBox(document)
            let layers = await BlockingWork.run { box.layerText() }
            // The cursor can have moved to another file while a long document was being read.
            guard pdfView.document === document else { return "" }
            pages = PagedDocumentText(layerText: layers)
            hasReadPages = true
        }
        startReadingScannedPages()
        return pages.text
    }

    /// Draw the matches on the pages in view, the current one in orange.
    func showFindMatches() {
        removeFindHighlights()
        guard let matches = find.matches, !matches.isEmpty else { return }
        var selections: [PDFSelection] = []
        for index in highlightableIndices(of: matches) {
            let isCurrent = index == find.current
            for placement in pages.placement(of: matches.ranges[index]) {
                switch placement {
                case let .layer(page, range):
                    guard let selection = selection(onPage: page, range: range) else { continue }
                    selection.color = isCurrent ? Self.currentMatchColor : Self.matchColor
                    selections.append(selection)
                case let .recognized(page, quads):
                    drawRecognizedMatch(quads, onPage: page, isCurrent: isCurrent)
                }
            }
        }
        highlighted = selections
        pdfView.highlightedSelections = selections.isEmpty ? nil : selections
    }

    func removeFindHighlights() {
        for drawn in recognizedHighlights {
            drawn.page.removeAnnotation(drawn.annotation)
        }
        recognizedHighlights = []
        guard !highlighted.isEmpty || pdfView.highlightedSelections != nil else { return }
        highlighted = []
        pdfView.highlightedSelections = nil
    }

    /// Scroll the current match into view and, where there is text behind it, make it the view's own
    /// selection so ⌘C copies what the bar found.
    ///
    /// A recognized page has nothing to select, so it is scrolled to by the outline instead: what is
    /// on screen is the page's picture, and there is no text on it to put on the pasteboard.
    func revealCurrentMatch() {
        guard let range = find.currentRange else { return }
        guard let first = pages.placement(of: range).first else { return }
        switch first {
        case let .layer(page, pageRange):
            guard let selection = selection(onPage: page, range: pageRange) else { return }
            pdfView.go(to: selection)
            pdfView.setCurrentSelection(selection, animate: false)
        case let .recognized(page, quads):
            guard let page = pdfView.document?.page(at: page), let box = pageRect(
                of: quads,
                on: page
            )
            else { return }
            pdfView.go(to: box, on: page)
        }
        // The pages in view have changed, so which matches are worth drawing has too.
        redrawHighlightsForVisiblePages()
    }

    /// Where a search with no current match begins: the start of the first page on screen.
    func findAnchorOffset() async -> Int {
        guard let page = pdfView.visiblePages.first ?? pdfView.currentPage,
              let document = pdfView.document
        else { return 0 }
        return pages.offset(ofPage: document.index(for: page)) ?? 0
    }

    /// The bar set up for finding, and the view reporting its scrolls so the highlights can follow
    /// the reader down the document.
    func installFinding() {
        filterBar.useForFinding()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visiblePagesMoved(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
    }

    // MARK: - Private

    /// The current match's color. The others take the find yellow the other surfaces mark with.
    private static var currentMatchColor: NSColor { .systemOrange }
    private static var matchColor: NSColor { .findHighlightColor }

    /// How many pages either side of those on screen carry highlights, so a short scroll shows
    /// matches already drawn.
    private static let pageMargin = 1

    @objc private func visiblePagesMoved(_ notification: Notification) {
        guard find.matches != nil else { return }
        redrawHighlightsForVisiblePages()
    }

    private func redrawHighlightsForVisiblePages() {
        guard find.matches != nil else { return }
        showFindMatches()
    }

    /// Which matches are worth drawing: those on the pages in view and their immediate neighbours.
    /// Everything off screen is left undrawn — a one-letter query over a long document has tens of
    /// thousands of matches, and `highlightedSelections` is assigned whole on every keystroke.
    private func highlightableIndices(of matches: TextFindMatches) -> Range<Int> {
        guard let document = pdfView.document else { return 0..<0 }
        let visible = pdfView.visiblePages.map { document.index(for: $0) }
        guard let lowest = visible.min(), let highest = visible.max() else {
            return 0..<min(matches.count, 1)
        }
        let first = max(0, lowest - Self.pageMargin)
        let last = min(pages.readyCount - 1, highest + Self.pageMargin)
        guard first <= last,
              let start = pages.offset(ofPage: first),
              let end = pages.offset(ofPage: last).map({ $0 + pages.segments.lengths[last] })
        else { return 0..<0 }
        return matches.indices(overlapping: start..<end)
    }

    /// The selection a match's offsets name on a page that has a text layer.
    private func selection(onPage index: Int, range: Range<Int>) -> PDFSelection? {
        guard let page = pdfView.document?.page(at: index) else { return nil }
        return page.selection(for: NSRange(location: range.lowerBound, length: range.count))
    }

    /// Mark a match on a page that had to be read, by putting a highlight annotation over each word
    /// it covers.
    ///
    /// A highlight annotation rather than a drawn overlay because PDFKit then scrolls and zooms it
    /// with the page for nothing, and because it is the shape a PDF already has for this. Its
    /// `quadrilateralPoints` are **relative to the annotation's own bounds**, which is the trap
    /// here: measured, page-space points draw *nothing at all* — no error, no warning, an invisible
    /// highlight — while the same four points relative to the bounds draw the full word, and the
    /// PDF spec's own order (upper-left, upper-right, lower-left, lower-right) is the one that
    /// covers it rather than a bowtie.
    private func drawRecognizedMatch(_ quads: [TextQuad], onPage index: Int, isCurrent: Bool) {
        guard let page = pdfView.document?.page(at: index) else { return }
        for quad in quads {
            guard let bounds = pageRect(of: [quad], on: page) else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = isCurrent ? Self.currentMatchColor : Self.matchColor
            annotation.quadrilateralPoints = [
                point(quad.topLeft, on: page, relativeTo: bounds),
                point(quad.topRight, on: page, relativeTo: bounds),
                point(quad.bottomLeft, on: page, relativeTo: bounds),
                point(quad.bottomRight, on: page, relativeTo: bounds)
            ]
            page.addAnnotation(annotation)
            recognizedHighlights.append((page, annotation))
        }
    }

    /// The upright box some outlines cover, in the page's own coordinates.
    private func pageRect(of quads: [TextQuad], on page: PDFPage) -> CGRect? {
        let media = page.bounds(for: .mediaBox)
        var box: CGRect?
        for quad in quads where quad.isDrawable {
            let normalized = quad.boundingBox
            let rect = CGRect(
                x: media.minX + normalized.x * media.width,
                y: media.minY + normalized.y * media.height,
                width: normalized.width * media.width,
                height: normalized.height * media.height
            )
            box = box.map { $0.union(rect) } ?? rect
        }
        return box
    }

    /// One corner, in the coordinates a highlight annotation shapes itself in: its own bounds.
    private func point(_ corner: TextPoint, on page: PDFPage, relativeTo bounds: CGRect) -> NSValue {
        let media = page.bounds(for: .mediaBox)
        return NSValue(point: NSPoint(
            x: media.minX + corner.x * media.width - bounds.minX,
            y: media.minY + corner.y * media.height - bounds.minY
        ))
    }
}

/// A `PDFDocument` carried across to a background thread to have its pages' text read.
///
/// `@unchecked Sendable` because `PDFDocument` is not `Sendable` and the read has to happen off the
/// main actor — measured safe, and deliberately narrow: nothing but reading is done through this,
/// the document is not mutated, and the result that comes back is plain values.
final class PDFDocumentBox: @unchecked Sendable {
    private let document: PDFDocument

    init(_ document: PDFDocument) {
        self.document = document
    }

    /// Each page's own text layer, `nil` for a page that has none.
    ///
    /// Page by page rather than `PDFDocument.string`, which is those same pages joined and cannot
    /// say which of them were empty — and the empty ones are exactly the ones that have to be read.
    func layerText() -> [String?] {
        (0..<document.pageCount).map { document.page(at: $0)?.string }
    }
}
