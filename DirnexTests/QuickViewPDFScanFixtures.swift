import AppKit
import DirnexCore
import PDFKit
import Testing

@testable import Dirnex

/// A PDF with scanned pages in it, and a stand-in for what reads them.
///
/// A *scanned* page here is a real one: the word is drawn into a bitmap and the bitmap into the
/// page, so the page carries no text layer at all — `PDFPage.string` is `nil`, which is the state
/// the whole feature exists for and which a page drawn with glyphs cannot reproduce.
@MainActor
enum QuickViewPDFScanFixtures {
    enum Page {
        /// A page drawn with real glyphs, so it carries its own text.
        case text(String)
        /// A page that is a picture of its words, so it carries none.
        case scanned(String)
    }

    struct Fixture {
        let preview: QuickViewPreviewView
        let surface: QuickViewPDFSurface
        let recognizer: FakePageTextRecognizer
    }

    /// Kept for the life of the process — tearing a window down while AppKit is still settling it
    /// crashes a later test (docs/NOTES.md ▸ Testing).
    private static var windows: [NSWindow] = []

    static func document(pages: [Page]) -> PDFDocument? {
        QuickViewPreviewView.mergedDocument(pages.map(data(of:)))
    }

    /// Three pages: one carrying its own text, two that have to be read.
    ///
    /// The fake's answers stand for what reading them would find — `beta` on the first and `beta
    /// omega` on the second — because what Vision makes of a picture is not this suite's subject.
    static func scanned(function: String = #function) async throws -> Fixture {
        try await fixture(
            pages: [.text("alpha beta gamma"), .scanned("delta beta"), .scanned("beta omega")],
            answers: [
                1: recognizedLine("delta beta"),
                2: recognizedLine("beta omega")
            ],
            function: function
        )
    }

    /// A document whose pages all carry their own text — the control, where nothing is read.
    static func textOnly(function: String = #function) async throws -> Fixture {
        try await fixture(pages: [.text("alpha beta gamma")], answers: [:], function: function)
    }

    /// A line of words laid across the middle of a page, the shape Vision answers in: each word's
    /// own outline, in the page's normalized coordinates with the origin at the bottom left.
    static func recognizedLine(_ line: String) -> RecognizedPageText {
        var words: [RecognizedWord] = []
        var start = 0
        var x = 0.1
        for word in line.split(separator: " ") {
            let length = word.utf16.count
            let width = Double(length) * 0.02
            words.append(RecognizedWord(
                range: start..<(start + length),
                quad: TextQuad(
                    topLeft: TextPoint(x: x, y: 0.52),
                    topRight: TextPoint(x: x + width, y: 0.52),
                    bottomLeft: TextPoint(x: x, y: 0.48),
                    bottomRight: TextPoint(x: x + width, y: 0.48)
                )
            ))
            start += length + 1
            x += width + 0.02
        }
        return RecognizedPageText(text: line, words: words)
    }

    /// Wait for every page to be read and for the search that follows the last one.
    static func finishReading(_ surface: QuickViewPDFSurface) async {
        await surface.recognitionTask?.value
        await surface.find.task?.value
    }

    // MARK: - Private

    private static func fixture(
        pages: [Page],
        answers: [Int: RecognizedPageText],
        function: String
    ) async throws -> Fixture {
        let recognizer = FakePageTextRecognizer()
        recognizer.answers = answers
        let preview = QuickViewPreviewView(
            backingColor: .textBackgroundColor,
            header: .none,
            findOptions: QuickViewFindOptionsStore.scratch(function: function),
            pageRecognizer: recognizer
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        windows.append(window)
        let container = try #require(window.contentView)
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.layoutSubtreeIfNeeded()
        preview.showPDFDocument(document(pages: pages))
        container.layoutSubtreeIfNeeded()
        let surface = try #require(preview.pdfSurface)
        return Fixture(preview: preview, surface: surface, recognizer: recognizer)
    }

    private static func data(of page: Page) -> Data {
        let box = CGRect(x: 0, y: 0, width: 400, height: 300)
        let data = NSMutableData()
        var mediaBox = box
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return Data() }
        context.beginPDFPage(nil)
        switch page {
        case let .text(line):
            draw(line, in: context, at: CGPoint(x: 30, y: 150))
        case let .scanned(line):
            if let image = raster(line, size: box.size) {
                context.draw(image, in: box)
            }
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func draw(_ line: String, in context: CGContext, at point: CGPoint) {
        let drawn = CTLineCreateWithAttributedString(NSAttributedString(
            string: line,
            attributes: [.font: NSFont(name: "Helvetica", size: 18) ?? .systemFont(ofSize: 18)]
        ))
        context.textPosition = point
        CTLineDraw(drawn, context)
    }

    /// The words as pixels — what makes the page a scan rather than a page of text.
    ///
    /// Drawn at 3× and large, because the point of this fixture is that the *real* recognizer can
    /// read one of them: at the page's own 72 dpi a rendered word is too coarse to be read back
    /// reliably, which would make that one test flaky about the framework rather than about us.
    private static func raster(_ line: String, size: CGSize) -> CGImage? {
        let scale: CGFloat = 3
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let drawn = CTLineCreateWithAttributedString(NSAttributedString(
            string: line,
            attributes: [.font: NSFont(name: "Helvetica", size: 48) ?? .systemFont(ofSize: 48)]
        ))
        context.textPosition = CGPoint(x: 60, y: CGFloat(height) / 2)
        CTLineDraw(drawn, context)
        return context.makeImage()
    }
}

/// What stands in for Vision: canned answers, a record of which pages were asked for, and a gate so
/// a test can stop a reading half way.
///
/// The record is the evidence, not the result: "does stopping reach the work" can only be answered
/// by what the work was *asked* to do (docs/NOTES.md ▸ Testing).
@MainActor
final class FakePageTextRecognizer: PDFPageTextRecognizing {
    /// What reading each page finds. A page with no entry reads as nothing, which is what a page
    /// that could not be read does.
    var answers: [Int: RecognizedPageText] = [:]
    /// Whether each page waits to be let go, so a test can hold a reading open.
    var holdEachPage = false
    /// Which pages were asked for, in order.
    private(set) var asked: [Int] = []

    private var waiting: [CheckedContinuation<Void, Never>] = []

    func recognizeText(ofPage index: Int, in document: PDFDocument) async -> RecognizedPageText? {
        asked.append(index)
        if holdEachPage {
            await withCheckedContinuation { continuation in
                waiting.append(continuation)
            }
        }
        return answers[index]
    }

    /// Let every held page finish, and every later one through.
    func releaseAll() {
        holdEachPage = false
        releaseHeld()
    }

    /// Let the pages held right now finish, and go on holding the ones after them — so a test can
    /// step a reading one page at a time rather than only starting and finishing it.
    func releaseHeld() {
        let held = waiting
        waiting = []
        held.forEach { $0.resume() }
    }
}
