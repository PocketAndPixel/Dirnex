import AppKit
import DirnexCore
import PDFKit
import Testing

@testable import Dirnex

/// Finding text in Quick View's PDF preview (2026-09-17). Which text matches is `DirnexCore`'s and
/// tested there (`TextFindMatchesTests`); the page arithmetic is `TextSegmentMapTests`'. What is
/// left is what this surface does with both — that a match found in the whole document's text comes
/// back as a selection on the page that really holds it, what is drawn on it, and that a new
/// document forgets it.
@Suite("Quick View PDF find", .serialized)
@MainActor
struct QuickViewPDFFindTests {
    private typealias Typing = QuickViewTableFilterFixtures

    @Test("typing finds every occurrence across the pages, ignoring case, the first one current")
    func findsEveryOccurrence() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        // One on page one, one on page two, one on page three — the last upper case.
        #expect(surface.find.matches?.count == 3)
        #expect(surface.find.current == 0)
        #expect(surface.filterBar.countLabel.stringValue.contains("3"))
        #expect(surface.filterBar.columnPicker.isHidden)
    }

    /// The assertion that the page arithmetic is right rather than merely plausible: a match found
    /// at an offset into the *whole* document's text has to come back as a selection whose text is
    /// the word, on the page that holds it. An off-by-one in the join would give a neighbouring word
    /// or the wrong page, both of which look like a working find.
    @Test("a match becomes a selection of that word, on the page that holds it")
    func matchesMapBackToTheirPages() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        let document = try #require(surface.pdfView.document)
        try await Typing.type("beta", into: surface)
        let matches = try #require(surface.find.matches)
        let found = matches.ranges.compactMap { range -> (String, Int)? in
            guard let selection = QuickViewPDFFindFixtures.selection(for: range, in: surface),
                  let page = selection.pages.first
            else { return nil }
            return (selection.string ?? "", document.index(for: page))
        }
        #expect(found.map(\.0) == ["beta", "beta", "BETA"])
        #expect(found.map(\.1) == [0, 1, 2])
    }

    @Test("the matches near the reader are drawn, the current one in its own color")
    func drawsTheMatches() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        let drawn = try #require(surface.pdfView.highlightedSelections)
        #expect(!drawn.isEmpty)
        #expect(drawn.contains { $0.color == .systemOrange })
        #expect(drawn.allSatisfy { $0.color == .systemOrange || $0.color == .findHighlightColor })
        // Exactly one is the current match.
        #expect(drawn.filter { $0.color == .systemOrange }.count == 1)
    }

    @Test("the current match becomes the view's own selection, so ⌘C copies what was found")
    func currentMatchIsSelected() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.pdfView.currentSelection?.string == "beta")
    }

    @Test("stepping moves the current match and wraps past either end")
    func steppingWraps() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        let down = #selector(NSResponder.moveDown(_:))
        let up = #selector(NSResponder.moveUp(_:))
        try Typing.editor(of: surface).doCommand(by: down)
        #expect(surface.find.current == 1)
        #expect(surface.pdfView.currentSelection?.string == "beta")
        try Typing.editor(of: surface).doCommand(by: down)
        #expect(surface.find.current == 2)
        #expect(surface.pdfView.currentSelection?.string == "BETA")
        try Typing.editor(of: surface).doCommand(by: down)
        #expect(surface.find.current == 0)
        try Typing.editor(of: surface).doCommand(by: up)
        #expect(surface.find.current == 2)
        #expect(surface.filterHasKeyboard)
    }

    @Test("clearing the text takes every highlight off")
    func clearingRemovesTheHighlights() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.pdfView.highlightedSelections?.isEmpty == false)
        try await Typing.type("", into: surface)
        #expect(surface.pdfView.highlightedSelections == nil)
        #expect(surface.find.matches == nil)
    }

    @Test("a word found nowhere says so and highlights nothing")
    func noMatches() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("zzzznotthere", into: surface)
        #expect(surface.find.matches?.isEmpty == true)
        #expect(surface.pdfView.highlightedSelections == nil)
        #expect(!surface.filterBar.countLabel.stringValue.isEmpty)
    }

    /// The document's text is read once and kept, because `PDFDocument.string` costs 370–420 ms on a
    /// long manual the first time. A second search must not read it again, and must not go stale.
    @Test("the document's text is read once and reused")
    func textIsReadOnce() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.hasReadPages)
        let first = surface.pages.text
        try await Typing.type("gamma", into: surface)
        #expect(surface.pages.text == first)
        #expect(surface.find.matches?.count == 1)
    }

    /// Which *engine* is doing the matching, pinned rather than assumed.
    ///
    /// `PDFDocument.findString` was the other candidate — 28× faster, since it needs no text
    /// extraction — and it does not agree: probed, it folds ß against ss, matches a ﬁ ligature
    /// against `fi`, finds a Kelvin sign for `k`, and matches `cafe` against `café`. `FilterQuery`
    /// counts accents, which is how every other Quick View surface matches. Reached for `findString`
    /// instead and this is the test that goes red.
    @Test("accents count, as they do everywhere else the filter bar matches")
    func accentsCount() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf(words: ["café society"])
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("cafe", into: surface)
        #expect(surface.find.matches?.isEmpty == true)
        try await Typing.type("café", into: surface)
        #expect(surface.find.matches?.count == 1)
    }

    @Test("a new document forgets the matches, its text and the bar")
    func newDocumentForgets() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.find.matches != nil)
        #expect(surface.hasReadPages)

        fixture.preview.showPDFDocument(QuickViewPDFFindFixtures.document(words: ["nothing here"]))
        #expect(surface.find.matches == nil)
        #expect(surface.find.current == nil)
        #expect(!surface.hasReadPages)
        #expect(surface.pages.text.isEmpty)
        #expect(surface.filterBar.isHidden)
        #expect(surface.pdfView.highlightedSelections == nil)
    }

    @Test("View ▸ Filter offers a PDF, and its bar keeps the mouse")
    func theCommandReachesTheSurface() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        #expect(fixture.preview.filterableSurface === fixture.surface)
        fixture.surface.beginFiltering()
        fixture.preview.layoutSubtreeIfNeeded()
        let inBar = NSPoint(x: 60, y: fixture.preview.bounds.maxY - 15)
        let hit = try #require(fixture.preview.hitTest(inBar))
        #expect(hit.isDescendant(of: fixture.surface.filterBar))
    }

    /// The surface gained a container when the bar arrived; everything that zooms or reads the
    /// document still reaches the `PDFView` itself.
    @Test("the PDF view is still what the preview hands out")
    func pdfViewIsStillReachable() async throws {
        let fixture = try await QuickViewPDFFindFixtures.pdf()
        defer { fixture.cleanup() }
        #expect(fixture.preview.pdfView === fixture.surface.pdfView)
        #expect(fixture.preview.pdfView?.document != nil)
    }
}

@MainActor
enum QuickViewPDFFindFixtures {
    struct Fixture {
        let preview: QuickViewPreviewView
        let surface: QuickViewPDFSurface

        func cleanup() {}
    }

    /// Kept for the life of the process — tearing a window down while AppKit is still settling it
    /// crashes a later test (docs/NOTES.md ▸ Testing).
    private static var windows: [NSWindow] = []

    /// One page per entry, each drawn with real glyphs so `PDFDocument.string` has something to
    /// extract.
    static func document(words: [String]) -> PDFDocument? {
        let pages = words.map { line -> Data in
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 400, height: 300)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil)
            else { return Data() }
            context.beginPDFPage(nil)
            let drawn = CTLineCreateWithAttributedString(NSAttributedString(
                string: line,
                attributes: [.font: NSFont(name: "Helvetica", size: 18) ?? .systemFont(ofSize: 18)]
            ))
            context.textPosition = CGPoint(x: 30, y: 150)
            CTLineDraw(drawn, context)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
        return QuickViewPreviewView.mergedDocument(pages)
    }

    /// A surface showing a three-page document whose pages each hold one `beta`, the last upper
    /// case — so a match on every page, and case folding to prove.
    static func pdf(words: [String]? = nil) async throws -> Fixture {
        let preview = QuickViewPreviewView(
            backingColor: .textBackgroundColor,
            header: .none,
            findOptions: QuickViewFindOptionsStore.scratch()
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
        preview.showPDFDocument(document(words: words ?? [
            "alpha beta gamma",
            "delta beta epsilon",
            "zeta BETA eta"
        ]))
        container.layoutSubtreeIfNeeded()
        let surface = try #require(preview.pdfSurface)
        return Fixture(preview: preview, surface: surface)
    }

    /// The selection a match's offsets name, built the way the surface builds it — through the page
    /// map, so the test spends the same arithmetic the product does rather than re-deriving it.
    static func selection(for range: Range<Int>, in surface: QuickViewPDFSurface) -> PDFSelection? {
        guard let document = surface.pdfView.document else { return nil }
        let pieces = surface.pages.segments.split(range)
        guard let piece = pieces.first, let page = document.page(at: piece.index) else { return nil }
        return page.selection(
            for: NSRange(location: piece.range.lowerBound, length: piece.range.count)
        )
    }
}
