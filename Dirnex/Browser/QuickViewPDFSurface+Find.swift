import AppKit
import DirnexCore
import PDFKit

/// Finding text in Quick View's PDF preview, which is also every Pages, Numbers and Keynote document
/// (`QuickViewPreviewView+Document` merges those into one PDF) — 2026-09-18.
///
/// The bar and its keys are the table's (`QuickViewFilterHost`), and the state machine is the one
/// every finding surface runs (`QuickViewFindHost`). What is this surface's own:
///
/// **What the text is.** `PDFDocument.string`, read once off the main actor and kept — 370–420 ms
/// for a 231-page manual the first time and 1 ms afterwards, measured, and measured safe to read on
/// a background thread while the main thread lays the same document out (3 runs, 213–217 concurrent
/// layout passes, no crash and an exact result). Matching is `DirnexCore`'s
/// (``DirnexCore/TextFindMatches``) rather than `PDFDocument.findString`, which is faster and does
/// not agree with it: probed, PDFKit folds ß against ss, matches a ﬁ ligature against `fi`, and
/// finds a Kelvin sign for `k`, where every other Quick View surface matches the way the table and
/// tree filters do. A find bar that counted differently depending on which preview was up would be
/// the same bar telling two stories.
///
/// **How a match is found again on a page.** The whole text is the pages joined by one newline —
/// verified on documents of 1, 78 and 231 pages, where re-joining reproduced `PDFDocument.string`
/// byte for byte — so ``DirnexCore/TextSegmentMap`` turns an offset into the page holding it, and
/// `PDFPage.selection(for:)` turns that into something the view can draw and scroll to. A match
/// running across a page break becomes a selection on each page rather than being dropped.
///
/// **How a match is drawn.** `highlightedSelections`, the current one in orange and the rest in the
/// find yellow. Only the matches on the pages nearby carry a selection: assigning 20 000 of them
/// costs 88 ms and building 58 000 costs 48 ms, which is a price per keystroke rather than per
/// document, and `PDFView.visiblePages` makes "nearby" exact.
extension QuickViewPDFSurface: QuickViewFindHost {
    var filterContentView: NSView { pdfView }

    var hasFilterableContent: Bool { pdfView.document != nil }

    var keyboardFallback: NSView { pdfView }

    /// The document's text, read once. Off the main actor, where it belongs: nearly half a second on
    /// a long manual is not a keystroke's worth of main-thread time.
    func findableText() async -> String {
        if hasReadDocumentText { return documentText }
        guard let document = pdfView.document else { return "" }
        let box = PDFDocumentBox(document)
        let read = await BlockingWork.run { box.read() }
        // The cursor can have moved to another file while a long document was being read.
        guard pdfView.document === document else { return "" }
        documentText = read.text
        pageSegments = TextSegmentMap(lengths: read.pageLengths, separator: 1)
        hasReadDocumentText = true
        return documentText
    }

    /// Draw the matches on the pages in view, the current one in orange.
    func showFindMatches() {
        removeFindHighlights()
        guard let matches = find.matches, !matches.isEmpty else { return }
        var selections: [PDFSelection] = []
        for index in highlightableIndices(of: matches) {
            guard let selection = selection(for: matches.ranges[index]) else { continue }
            selection.color = index == find.current ? Self.currentMatchColor : Self.matchColor
            selections.append(selection)
        }
        highlighted = selections
        pdfView.highlightedSelections = selections.isEmpty ? nil : selections
    }

    func removeFindHighlights() {
        guard !highlighted.isEmpty || pdfView.highlightedSelections != nil else { return }
        highlighted = []
        pdfView.highlightedSelections = nil
    }

    /// Scroll the current match into view and make it the view's own selection, so ⌘C copies what
    /// the bar found.
    func revealCurrentMatch() {
        guard let range = find.currentRange, let selection = selection(for: range) else { return }
        pdfView.go(to: selection)
        pdfView.setCurrentSelection(selection, animate: false)
        // The pages in view have changed, so which matches are worth drawing has too.
        redrawHighlightsForVisiblePages()
    }

    /// Where a search with no current match begins: the start of the first page on screen.
    func findAnchorOffset() async -> Int {
        guard let page = pdfView.visiblePages.first ?? pdfView.currentPage,
              let document = pdfView.document
        else { return 0 }
        let index = document.index(for: page)
        guard index > 0, pageSegments.lengths.indices.contains(index) else { return 0 }
        return pageSegments.lengths.prefix(index).reduce(0) { $0 + $1 + 1 }
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
        let last = min(pageSegments.lengths.count - 1, highest + Self.pageMargin)
        guard first <= last else { return 0..<0 }
        let start = pageSegments.lengths.prefix(first).reduce(0) { $0 + $1 + 1 }
        let end = pageSegments.lengths.prefix(last + 1).reduce(0) { $0 + $1 + 1 }
        return matches.indices(overlapping: start..<end)
    }

    /// The selection a match's offsets name. A match inside one page is that page's selection; one
    /// running across a page break is the pieces on each page joined, so it draws on both.
    private func selection(for range: Range<Int>) -> PDFSelection? {
        guard let document = pdfView.document else { return nil }
        let pieces = pageSegments.split(range)
        var built: [PDFSelection] = []
        for piece in pieces {
            guard let page = document.page(at: piece.index),
                  let selection = page.selection(
                      for: NSRange(location: piece.range.lowerBound, length: piece.range.count)
                  )
            else { continue }
            built.append(selection)
        }
        guard let first = built.first else { return nil }
        guard built.count > 1 else { return first }
        let joined = PDFSelection(document: document)
        built.forEach(joined.add)
        return joined
    }
}

/// A `PDFDocument` carried across to a background thread to have its text read.
///
/// `@unchecked Sendable` because `PDFDocument` is not `Sendable` and the read has to happen off the
/// main actor — measured safe, and deliberately narrow: nothing but reading is done through this,
/// the document is not mutated, and the result that comes back is plain values.
private final class PDFDocumentBox: @unchecked Sendable {
    private let document: PDFDocument

    init(_ document: PDFDocument) {
        self.document = document
    }

    /// The whole text and each page's length in UTF-16 units — the units `TextFindMatches` counts
    /// and `PDFPage.selection(for:)` is addressed in.
    func read() -> (text: String, pageLengths: [Int]) {
        var lengths: [Int] = []
        lengths.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            lengths.append(document.page(at: index)?.string?.utf16.count ?? 0)
        }
        return (document.string ?? "", lengths)
    }
}
