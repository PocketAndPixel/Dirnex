import AppKit
import DirnexCore
import PDFKit

/// Reading a PDF's scanned pages so the find has something to search (2026-09-19).
///
/// A page made of a photograph has no text layer, so a find over it answers **"No matches"** —
/// which is not "there is nothing there", it is a confident wrong answer, and on the mixed books
/// this Mac carries (19 of 20 pages scanned) it is wrong about nearly the whole document while
/// looking exactly like a correct one.
///
/// Recognizing costs ~0.2–0.5 s a page and 40–65 s for a 142-page book, measured, and Vision does
/// not parallelize — 2, 4 and 8 pages at once took the same wall time as one at a time, so there is
/// nothing to win by running several. That leaves three rules, and all three are what makes it
/// affordable rather than merely possible:
///
/// - **It starts on the first keystroke and not before.** Opening the bar costs nothing; a query is
///   somebody asking a question a minute of machine time is the only way to answer. Nothing else in
///   Quick View spends this much unasked, and nothing here does either.
/// - **It reads in page order and appends.** A page's offsets are fixed once every page before it
///   is known (``DirnexCore/PagedDocumentText``), so matches found in the first pages keep their
///   numbers, their highlights and their place in the count while the rest are still being read.
///   The search is simply re-run as each page lands — a few milliseconds over a book's worth of
///   text, against the half-second that produced the page.
/// - **It stops the moment nobody is waiting.** The bar closed, the query cleared, another file
///   under the cursor: any of them ends the reading where it stands, and what was read is kept.
extension QuickViewPDFSurface {
    /// Read the scanned pages, if there are any and somebody is waiting for them.
    ///
    /// Safe to call on every keystroke: a reading already in flight is left alone, which is what
    /// keeps typing a second letter from starting a second pass over the same document.
    ///
    /// Whether anybody is waiting is deliberately **not** asked here. It was, and a negative
    /// control found the check inert: the loop asks it before its first page, so a reading nobody
    /// wants ends without having read anything either way. One rule in one place, at the cost of a
    /// task that starts and returns.
    func startReadingScannedPages() {
        guard pages.needsReading, !pages.isComplete, recognitionTask == nil,
              let document = pdfView.document
        else { return }
        let generation = recognitionGeneration
        recognitionTask = Task { [weak self] in
            await self?.readPages(of: document, generation: generation)
            // Only when the handle is still this reading's. A new document nils it and bumps the
            // generation, so a reading abandoned half a second ago would otherwise come back and
            // clear the *next* one's handle — after which the next page landing finds no reading in
            // flight and starts a second loop over the same document, and the two race to read the
            // same pages.
            guard let self, generation == recognitionGeneration else { return }
            recognitionTask = nil
        }
    }

    /// Whether anyone is waiting on a page being read: the bar is up and something is typed in it.
    ///
    /// Read before every page rather than once, because it is also what *stops* the reading — a
    /// reader who closes the bar or clears the query has said they are no longer asking, and the
    /// next page is never started.
    var isReadingWanted: Bool {
        !filterBar.isHidden && !filterBar.query.isEmpty
    }

    // MARK: - Private

    /// One page at a time, in order, until they are read or nobody wants them.
    private func readPages(of document: PDFDocument, generation: Int) async {
        while let next = pages.unreadPages.first {
            guard generation == recognitionGeneration, isReadingWanted,
                  pdfView.document === document
            else { return }
            let read = await recognizer.recognizeText(ofPage: next, in: document)
            // The document can have been replaced, or the reading abandoned, while this page was
            // being read — half a second is long enough for the cursor to have moved twice.
            guard generation == recognitionGeneration, pdfView.document === document else { return }
            // A page that could not be read counts as read and as empty. Anything else stalls the
            // whole document behind it, since the text can only grow at its end.
            pages.set(.recognized(read ?? RecognizedPageText(text: "", words: [])), at: next)
            searchWhatHasBeenRead()
        }
    }

    /// Run the query again over the text as it now stands, and say how far the reading has got.
    ///
    /// `filterChanged()` rather than anything narrower: it is the one funnel that reads the bar's
    /// text *and* its options, discards a search the reader has moved past, and re-anchors the
    /// current match — and because the text only ever grows at its end, re-running it cannot move a
    /// match that was already found. A second, narrower spelling of it here would be the duplicated
    /// rule this project keeps paying for.
    ///
    /// Flagged as a re-run first, because nobody asked for this one: it must not scroll the
    /// document under a reader who is reading it (``QuickViewFind/isRerunForMoreText``).
    private func searchWhatHasBeenRead() {
        find.isRerunForMoreText = true
        filterChanged()
    }
}
