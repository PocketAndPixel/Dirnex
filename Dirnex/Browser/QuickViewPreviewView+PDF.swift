import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Quick View's PDFKit backend: PDFs, and — since the office-document route — the pages an iWork
/// document is converted into (`QuickViewPreviewView+Document`). Split from `QuickViewPreviewView`
/// when that second caller arrived, to stay under SwiftLint's `file_length`.
///
/// `PDFView` rather than Quick Look because Quick Look only wires up magnify-to-zoom for
/// *single-page* PDFs; `PDFView` zooms, scrolls and selects every document.
extension QuickViewPreviewView {
    /// Show `url` in the PDFKit backend, standing down the others.
    func showPDF(_ url: URL) {
        showPDFDocument(PDFDocument(url: url))
    }

    /// Show `document`, standing down the others. `fitsWidth` refits the page to the surface for each
    /// new document; `false` shows it at its own size, which is what a converted spreadsheet asks for
    /// (`QuickViewPreviewView+Document`). Either way the user can then pinch to zoom in or out.
    func showPDFDocument(_ document: PDFDocument?, fitsWidth: Bool = true) {
        let pdfView = ensurePDFView()
        standDownQuickLook()
        standDownImage()
        standDownText()
        standDownWeb()
        pdfView.isHidden = false
        // A view built a moment ago has no frame yet, and a scale worked out against a zero frame is
        // what the position below would then be relative to.
        content.layoutSubtreeIfNeeded()
        pdfView.document = document
        pdfView.autoScales = fitsWidth
        if !fitsWidth { pdfView.scaleFactor = 1 }
        // Open at the top of page one. Left to itself `PDFView` rescales *after* taking the document
        // and keeps its old centre, so the first line lands off screen: measured in a harness at
        // y ≈ 675 of an 842-pt page, for a plain PDF and a merged iWork document alike, and seen live
        // as a Pages preview opening partway down its first page.
        if let first = document?.page(at: 0) {
            pdfView.layoutDocumentView()
            let top = CGPoint(x: 0, y: first.bounds(for: pdfView.displayBox).maxY)
            pdfView.go(to: PDFDestination(page: first, at: top))
        }
        // Rasterize page one *now* rather than letting PDFKit do it lazily. Parsing a PDF is
        // nearly free (measured 0.2 ms) but the first page render is not, and lazily it landed
        // ~30 ms into the swipe's flip animation and cost four frames of it — the judder was
        // reproducible on every flip into a PDF. Paid here it costs the same 3–8 ms while nothing
        // is moving. The thumbnail itself is discarded; warming the page cache is the point.
        _ = document?.page(at: 0)?.thumbnail(of: bounds.size, for: .mediaBox)
    }

    func standDownPDF() {
        pdfView?.isHidden = true
        pdfView?.document = nil
    }

    /// Whether `url` is a PDF, so it routes to `PDFView`. Prefers the file's real content type
    /// (catches an odd extension) and falls back to the extension when that can't be read.
    static func isPDF(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .pdf)
        }
        return url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
    }

    /// Build the PDFKit backend on first use. Continuous single-page layout scrolls a multi-page
    /// document naturally, and `PDFView` handles pinch-to-zoom itself.
    private func ensurePDFView() -> PDFView {
        if let pdfView { return pdfView }
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        // The full-screen surface is deliberately black behind the page; the others follow the
        // window. Reusing this view's own backing keeps the two consistent for free.
        view.backgroundColor = backingColor
        pin(view, inside: content)
        pdfView = view
        return view
    }
}
