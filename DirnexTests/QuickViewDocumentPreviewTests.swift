import AppKit
import CoreText
import DirnexCore
import PDFKit
import Testing

@testable import Dirnex

/// Quick View's office-document and rich-text backends, on the app side (follow-on, 2026-09-14). The
/// reading of a generator's bundle is `DirnexCore`'s (`QuickLookPreviewBundle`) and is tested there
/// against captured bytes; what is left here is which files take these routes, one conversion through
/// the real `qlmanage`, and the crash the merged iWork document caused the first time it was shown.
///
/// Serialized because two tests share one piece of external state, the converter's temp root: run in
/// parallel, the Word conversion's directory showed up in the declined document's before-and-after
/// comparison (measured, the first run of this suite).
@Suite("Quick View document preview", .serialized)
@MainActor
struct QuickViewDocumentPreviewTests {
    // MARK: - Routing

    @Test("Office and iWork documents take the conversion route")
    func routesOfficeDocuments() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let names = [
            "letter.docx", "letter.doc", "budget.xlsx", "budget.xls", "deck.pptx", "deck.ppt",
            "report.pages", "table.numbers", "talk.key"
        ]
        for name in names {
            let url = try tree.write(name, contents: "x")
            #expect(QuickViewPreviewView.isConvertibleDocument(url), "\(name) should be converted")
        }
    }

    /// The Office generator claims CSV too, and a CSV is text — the table and text backends keep it.
    @Test("CSV, text, PDFs, images and rich text do not")
    func leavesOtherFilesAlone() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["data.csv", "notes.txt", "paper.pdf", "photo.jpg", "letter.rtf", "essay.odt"] {
            let url = try tree.write(name, contents: "x")
            #expect(
                !QuickViewPreviewView.isConvertibleDocument(url),
                "\(name) should not be converted"
            )
        }
    }

    @Test("the route is read from the generators on this Mac, and is not text")
    func typesComeFromTheGenerators() {
        let types = QuickViewPreviewView.convertibleDocumentTypes
        #expect(types.contains(.init("org.openxmlformats.wordprocessingml.document")!))
        #expect(types.contains(.init("com.apple.iwork.pages.sffpages")!))
        #expect(!types.contains { $0.conforms(to: .text) })
    }

    @Test("RTF, RTFD and OpenDocument text take the rich-text route; Word does not")
    func routesRichText() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["letter.rtf", "essay.odt"] {
            let url = try tree.write(name, contents: "x")
            #expect(QuickViewPreviewView.isRichTextDocument(url), "\(name) should be rich text")
        }
        let package = tree.root.appendingPathComponent("notes.rtfd", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(QuickViewPreviewView.isRichTextDocument(package))
        // `NSAttributedString` reads Word too, and drops its images — the generator keeps them.
        #expect(
            try !QuickViewPreviewView.isRichTextDocument(tree.write("letter.docx", contents: "x"))
        )
    }

    // MARK: - Rich text on screen

    /// The reason the backend exists: RTF used to be drawn by Quick Look, where the surface has to
    /// swallow the click, so nothing in it could be selected.
    @Test("an RTF document keeps its formatting and the mouse")
    func richTextIsSelectableAndFormatted() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("letter.rtf", contents: #"{\rtf1\ansi Plain {\b Bold} text}"#)
        let preview = try await QuickViewTextPreviewTests.loaded(url)

        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        let textView = try #require(QuickViewTextPreviewTests.enclosingTextView(of: hit))
        try await Self.settle { textView.string == "Plain Bold text" }
        // Guarded rather than trusted: an out-of-range index *raises*, and an Objective-C exception
        // in a test wedges the host instead of failing the test.
        try #require(textView.textStorage?.length ?? 0 > 6)
        let bold = try #require(
            textView.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont
        )
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(textView.usesAdaptiveColorMappingForDarkAppearance)
    }

    @Test("a plain text file shown after a document is not color-mapped")
    func sourceTextIsNotColorMapped() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTextPreviewTests.loaded(
            tree.write("letter.rtf", contents: #"{\rtf1 Hi}"#)
        )
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        let textView = try #require(QuickViewTextPreviewTests.enclosingTextView(of: hit))
        try await Self.settle { textView.string == "Hi" }
        #expect(textView.usesAdaptiveColorMappingForDarkAppearance)

        try preview.show(tree.write("notes.txt", contents: "plain\n"), style: .source)
        try await Self.settle { textView.string == "plain\n" }
        #expect(!textView.usesAdaptiveColorMappingForDarkAppearance)
    }

    /// Wait for an asynchronous read to land — generous, since a satisfied predicate returns on the
    /// next poll and the budget only absorbs a busy main actor (docs/NOTES.md ▸ Testing).
    private static func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            try #require(Date() < deadline, "timed out waiting for the preview to load")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - The converter, against the real tool

    /// One real conversion. The document is written by AppKit, so the test needs no fixture, and the
    /// generator's answer for it was measured before this was written: a page, scripts allowed,
    /// `CenterContent` set.
    @Test("a Word document converts to a centered page carrying its text")
    func convertsWordDocument() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("Звіт.docx")
        let text = NSAttributedString(string: "Hello from a test document — Привіт")
        try text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        ).write(to: url)

        // Off the main actor: a real spawn, in a suite the rest of the host shares an actor with
        // (docs/NOTES.md ▸ Testing).
        let converted = await BlockingWork.run { QuickLookDocumentConverter.convert(url) { false } }
        let conversion = try #require(converted)
        defer { try? FileManager.default.removeItem(at: conversion.outputDirectory) }
        guard case let .page(allowsJavaScript, centersContent, fitWidth) = conversion.content else {
            Issue.record("expected a page, got \(conversion.content)")
            return
        }
        #expect(allowsJavaScript)
        #expect(centersContent)
        #expect((fitWidth ?? 0) > 0)
        let page = try String(contentsOf: conversion.page, encoding: .utf8)
        #expect(page.contains("Hello from a test document — Привіт"))
        #expect(page.contains("margin-left: auto !important"))
    }

    @Test("a document the generator declines converts to nothing and leaves nothing behind")
    func declinedDocumentLeavesNothing() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("broken.docx", contents: "not a zip at all")
        let root = QuickLookDocumentConverter.temporaryRoot
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])

        let converted = await BlockingWork.run { QuickLookDocumentConverter.convert(url) { false } }
        #expect(converted == nil)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        #expect(after.subtracting(before).isEmpty)
    }

    // MARK: - The merged iWork document

    /// The crash this backend shipped with for one live run. An iWork document's pages arrive as
    /// separate PDFs and are merged into one; a page inserted into another document does not keep its
    /// own document alive, and once that is released an accessibility client — VoiceOver, or anything
    /// that reads the window's elements — walking the view killed the process in
    /// `CGPDFPageCopyRootTaggedNode` on a recursively locked `os_unfair_lock`. Drawn pages reproduce it
    /// exactly as the generator's do (measured 3 of 3 either way), so the test makes its own.
    @Test("a merged PDF can be walked for accessibility once its parts are gone")
    func mergedDocumentSurvivesAccessibilityWalk() throws {
        let document = try #require(
            QuickViewPreviewView.mergedDocument((1...3).map { Self.pdf(text: "Page \($0) words") })
        )
        #expect(document.pageCount == 3)
        #expect(document.string?.contains("Page 2 words") == true)

        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 700))
        view.displayMode = .singlePageContinuous
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.document = document
        view.layoutDocumentView()
        Self.retained.append(window)

        #expect(Self.accessibilityElementCount(of: view) > 3)
    }

    /// Found by looking, not by a test: `PDFView` rescales after taking a document and keeps its old
    /// centre, so a Pages preview opened partway down its first page. Measured in a harness at
    /// y ≈ 675 of an 842-pt page before the fix; the top of the page is its height.
    @Test("a PDF opens at the top of its first page, and a sheet at its own size")
    func pdfOpensAtTheTop() async throws {
        let pages = (1...4).map { Self.pdf(text: "Page \($0) words") }
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        Self.retained.append(window)
        let content = try #require(window.contentView)
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        content.layoutSubtreeIfNeeded()

        preview.showPDFDocument(QuickViewPreviewView.mergedDocument(pages))
        let fitted = try #require(preview.pdfView)
        let destination = try #require(fitted.currentDestination)
        #expect(destination.page === fitted.document?.page(at: 0))
        // The drawn pages are 300 pt tall; within a point of it is the top.
        #expect(destination.point.y > 299)
        #expect(fitted.autoScales)

        preview.showPDFDocument(QuickViewPreviewView.mergedDocument(pages), fitsWidth: false)
        #expect(!fitted.autoScales)
        #expect(abs(fitted.scaleFactor - 1) < 0.001)
    }

    /// Windows built here are kept for the life of the test host rather than closed (docs/NOTES.md ▸
    /// Testing: tearing a window down mid-settle is its own crash).
    private static var retained: [NSWindow] = []

    private static func accessibilityElementCount(of element: Any, depth: Int = 0) -> Int {
        guard depth < 12, let children = (element as AnyObject).accessibilityChildren?() else { return 1 }
        return 1 + children.reduce(0) { $0 + accessibilityElementCount(of: $1, depth: depth + 1) }
    }

    /// A one-page PDF with `text` drawn as real glyphs.
    private static func pdf(text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
        )
        context.textPosition = CGPoint(x: 40, y: 150)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
