import DirnexCore
import PDFKit
import Vision

/// What turns a scanned page into text and outlines, for a find that has nothing else to search
/// (2026-09-19).
///
/// A protocol because the surface's half of this — reading a document a page at a time, searching
/// as the pages land, stopping when the reader stops caring — is a state machine worth testing
/// without a 0.3 s Vision call per page and without a scanned fixture in the repo.
@MainActor
protocol PDFPageTextRecognizing: AnyObject {
    /// Read page `index` of `document`. `nil` when there is nothing to read it from, which is not
    /// the same as a page that read as empty.
    func recognizeText(ofPage index: Int, in document: PDFDocument) async -> RecognizedPageText?
}

/// The real one: the page drawn into a bitmap and handed to Vision, and what it has already read.
///
/// Every constant here was measured on this Mac's scanned fixtures before any of it was written
/// (docs/NOTES.md ▸ Recognizing a scanned page).
@MainActor
final class VisionPageTextRecognizer: PDFPageTextRecognizing {
    /// One per process, so a reader who arrows off a scan and back onto it does not pay for it
    /// twice — what has been read is kept here rather than on the surface, which is rebuilt with
    /// every preview.
    static let shared = VisionPageTextRecognizer()

    /// How many times the page's own size the bitmap is — 144 dpi for the ordinary 72 dpi page.
    ///
    /// Measured against a 4× render of the same page: the two differ only in runs of dot leaders
    /// and one ligature, no word differs, while 1× loses real text. Above 2× the text stops
    /// changing and the bitmap keeps growing (a page at 2× is 2 MB).
    private nonisolated static let renderScale: CGFloat = 2

    /// In memory and nowhere else (``DirnexCore/RecognizedPageStore``).
    private var store = RecognizedPageStore()

    func recognizeText(ofPage index: Int, in document: PDFDocument) async -> RecognizedPageText? {
        let identity = Self.identity(of: document)
        if let identity, let read = store.pages(for: identity)[index] {
            store.touch(identity)
            return read
        }
        guard let page = document.page(at: index) else { return nil }
        let box = PDFPageBox(page)
        let scale = Self.renderScale
        let read = await BlockingWork.run { box.recognize(scale: scale) }
        if let identity, let read {
            store.store(read, at: index, for: identity)
        }
        return read
    }

    /// Which document this is, for the store to key on.
    ///
    /// The file's identity rather than its path, so a path that now names different bytes is a
    /// different document and is read again (``DirnexCore/ArchiveIdentity``). `nil` for a document
    /// with no file behind it, which simply means nothing is kept for it.
    private static func identity(of document: PDFDocument) -> ArchiveIdentity? {
        document.documentURL.flatMap { ArchiveIdentity.current(ofFileAt: $0.path) }
    }
}

/// A `PDFPage` carried to a background thread to be drawn and read.
///
/// `@unchecked Sendable` for the reason `PDFDocumentBox` is, and as narrowly: the page is drawn and
/// nothing else, and what comes back is plain values. Rendering and recognizing are ~0.2–0.5 s a
/// page, which is not main-actor work — and `BlockingWork` rather than a detached task because both
/// halves block (docs/NOTES.md ▸ Swift 6 and concurrency).
private final class PDFPageBox: @unchecked Sendable {
    private let page: PDFPage

    init(_ page: PDFPage) {
        self.page = page
    }

    func recognize(scale: CGFloat) -> RecognizedPageText? {
        guard let image = render(scale: scale) else { return nil }
        let request = VNRecognizeTextRequest()
        // `.accurate`, never `.fast`: measured on a scanned book, the fast path reads `Reading` as
        // `Readlng`, `Write` as `Wnte` and `answer` as `ansJYer`, at confidence 0.30–0.50 against
        // the accurate path's 1.00. A find over that text answers about words nobody wrote.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // The language list is deliberately left alone. Measured on macOS 26, a page of Ukrainian
        // read identically with `["en-US"]`, with `["uk-UA", "ru-RU", "en-US"]` and with nothing
        // set at all — so pinning a list buys nothing here and, on an OS that does respect it,
        // would be this app deciding which scripts a user may search.
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observations = request.results
        else { return nil }
        return assemble(observations)
    }

    // MARK: - Private

    /// The page as a bitmap, honouring its rotation.
    ///
    /// `bounds(for:)` reports the **unrotated** box whatever the rotation is, while
    /// `draw(with:to:)` does rotate what it draws (measured) — so a quarter-turned page drawn into
    /// a canvas sized from its own bounds is squeezed into the wrong aspect and cropped. Grayscale
    /// because Vision reads the same text from it and it is a third of the memory.
    private func render(scale: CGFloat) -> CGImage? {
        let media = page.bounds(for: .mediaBox)
        guard media.width > 1, media.height > 1 else { return nil }
        let quarterTurn = page.rotation % 180 != 0
        let width = Int((quarterTurn ? media.height : media.width) * scale)
        let height = Int((quarterTurn ? media.width : media.height) * scale)
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// The lines Vision read, joined into one page of text, with every word's outline beside it.
    ///
    /// The words are taken a run of non-whitespace at a time and their outlines asked for by range,
    /// never character by character: measured, `boundingBox(for:)` answers the *word's* box for
    /// every character in it, and answers a degenerate box at the page's corner for a lone space.
    private func assemble(_ observations: [VNRecognizedTextObservation]) -> RecognizedPageText {
        var text = ""
        var words: [RecognizedWord] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            if !text.isEmpty { text += RecognizedPageText.lineSeparator }
            let lineStart = text.utf16.count
            text += line
            for range in wordRanges(in: line) {
                guard let rectangle = try? candidate.boundingBox(for: range) else { continue }
                let start = lineStart + line.utf16.distance(
                    from: line.startIndex,
                    to: range.lowerBound
                )
                let end = lineStart + line.utf16.distance(
                    from: line.startIndex,
                    to: range.upperBound
                )
                words.append(RecognizedWord(range: start..<end, quad: quad(of: rectangle)))
            }
        }
        return RecognizedPageText(text: text, words: words)
    }

    /// Every run of non-whitespace in a line — a word, as far as an outline is concerned.
    private func wordRanges(in line: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var index = line.startIndex
        while index < line.endIndex {
            guard !line[index].isWhitespace else {
                index = line.index(after: index)
                continue
            }
            let start = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    /// Vision's rectangle, turned back into the unrotated page's own coordinates — the space a
    /// page's annotations are addressed in. The turn itself is ``DirnexCore/TextQuad/unrotated(by:)``,
    /// where it can be tested against the four measured cases without a PDF.
    private func quad(of rectangle: VNRectangleObservation) -> TextQuad {
        let asRead = TextQuad(
            topLeft: TextPoint(x: Double(rectangle.topLeft.x), y: Double(rectangle.topLeft.y)),
            topRight: TextPoint(x: Double(rectangle.topRight.x), y: Double(rectangle.topRight.y)),
            bottomLeft: TextPoint(
                x: Double(rectangle.bottomLeft.x),
                y: Double(rectangle.bottomLeft.y)
            ),
            bottomRight: TextPoint(
                x: Double(rectangle.bottomRight.x),
                y: Double(rectangle.bottomRight.y)
            )
        )
        return asRead.unrotated(by: page.rotation)
    }
}
