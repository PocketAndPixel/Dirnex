import AppKit
import DirnexCore
import PDFKit
import Testing
import WebKit

@testable import Dirnex

/// What a scroll move does to the two Quick View backends that do not scroll through a scroll view of
/// ours (2026-10-18): a PDF, whose `PDFView` keeps its own and says nothing when it moves, and a
/// rendered page, scrolled by script — a converted workbook's sheet inside its frame included. The
/// other backends are `QuickViewScrollSurfaceTests`'.
@Suite("Quick View scroll pages", .serialized)
@MainActor
struct QuickViewScrollPageTests {
    // MARK: - PDF

    private func pdfFixture(pages: Int) async throws -> QuickViewPDFFindFixtures.Fixture {
        try await QuickViewPDFFindFixtures.pdf(words: (1...pages).map { "page \($0) beta" })
    }

    /// The pages `PDFView` itself says are in view, once it has caught up with the scroll: it refreshes
    /// them lazily, and in the test host's window they read empty straight after a move.
    private func visiblePageIndices(_ surface: QuickViewPDFSurface) async throws -> [Int] {
        let document = try #require(surface.pdfView.document)
        let deadline = Date().addingTimeInterval(10)
        while surface.pdfView.visiblePages.isEmpty {
            try #require(Date() < deadline, "PDFView never reported the pages in view")
            try await Task.sleep(for: .milliseconds(10))
        }
        return surface.pdfView.visiblePages.map { document.index(for: $0) }
    }

    /// A PDF's document view is not flipped (measured), so this is the walk above with the axis
    /// reversed: toward the end is *down* the y axis.
    @Test("a PDF scrolls toward its end down an unflipped axis, and reaches both ends")
    func pdfScrolls() async throws {
        let fixture = try await pdfFixture(pages: 8)
        let surface = fixture.surface
        let window = try await QuickViewScrollFixtures.drawn(fixture.preview) { !surface.pdfView.visiblePages.isEmpty }
        defer { window.orderOut(nil) }
        let scrollView = try #require(surface.pdfView.documentView?.enclosingScrollView)
        let document = try #require(scrollView.documentView)
        #expect(!document.isFlipped)

        fixture.preview.scrollContent(.end)
        #expect(scrollView.documentVisibleRect.minY <= document.frame.minY + 1)
        #expect(try await visiblePageIndices(surface).contains(7))

        // At the top the view rests a title bar's height above the document (the fixture's window has
        // a full-size content view), so the document's top is in view rather than at the clip's edge.
        fixture.preview.scrollContent(.top)
        let top = scrollView.documentVisibleRect.maxY
        #expect(try await visiblePageIndices(surface).contains(0))
        #expect(top >= document.frame.maxY - 1)
        fixture.preview.scrollContent(.lineDown)
        #expect(
            abs(scrollView.documentVisibleRect.maxY - (top - QuickViewScrollFixtures.lineStep)) < 0.5
        )
    }

    /// `PDFView` posts no `PDFViewPageChanged` for a move of its clip view (measured), and the find
    /// draws only the matches near the pages in view — so without the surface redrawing after a
    /// keyboard scroll, the highlights would stay on the first pages while the reader is on the last.
    @Test("a scroll to the end of a PDF moves the find's highlights to the pages now in view")
    func pdfHighlightsFollowTheScroll() async throws {
        let fixture = try await pdfFixture(pages: 8)
        let surface = fixture.surface
        let window = try await QuickViewScrollFixtures.drawn(fixture.preview) { !surface.pdfView.visiblePages.isEmpty }
        defer { window.orderOut(nil) }
        let document = try #require(surface.pdfView.document)
        try await QuickViewTableFilterFixtures.type("beta", into: surface)
        let highlightedPages = {
            Set((surface.pdfView.highlightedSelections ?? []).flatMap(\.pages).map {
                document.index(for: $0)
            })
        }
        try #require(highlightedPages().contains(0))
        try #require(!highlightedPages().contains(7))

        fixture.preview.scrollContent(.end)
        #expect(highlightedPages().contains(7))
        #expect(!highlightedPages().contains(0))
    }

    // MARK: - Web

    private func javaScript(
        _ script: String,
        in webView: WKWebView,
        frame: WKFrameInfo? = nil
    ) async -> Double? {
        let value = try? await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: frame,
            contentWorld: .defaultClient
        )
        return (value as? NSNumber)?.doubleValue
    }

    private func scrollY(_ webView: WKWebView, frame: WKFrameInfo? = nil) async -> Double? {
        await javaScript("return window.scrollY", in: webView, frame: frame)
    }

    /// Poll until the page reports `expected`: the scroll is a script the surface fires and forgets.
    private func settle(
        _ webView: WKWebView,
        frame: WKFrameInfo? = nil,
        at expected: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        var last: Double?
        while Date() < deadline {
            last = await scrollY(webView, frame: frame)
            if let last, abs(last - expected) < 0.5 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(
            "scrollY is \(String(describing: last)), expected \(expected)",
            sourceLocation: sourceLocation
        )
    }

    @Test(
        "a rendered page steps a line and a page — the page by the core's rule — and reaches both ends"
    )
    func renderedPageScrolls() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let paragraphs = (1...300).map { "<p>Paragraph \($0)</p>" }.joined()
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(
            try tree.write("long.html", contents: "<meta charset=utf-8><body>\(paragraphs)</body>"),
            style: .rendered
        )
        let webView = try await QuickViewZoomFixtures.webView(in: preview)
        let deadline = Date().addingTimeInterval(10)
        while (await javaScript("return document.scrollingElement.scrollHeight", in: webView) ?? 0)
            < 2000 {
            try #require(Date() < deadline, "the page never laid out")
            try await Task.sleep(for: .milliseconds(10))
        }
        let view = try #require(await javaScript("return window.innerHeight", in: webView))
        let height = try #require(
            await javaScript("return document.scrollingElement.scrollHeight", in: webView)
        )

        preview.scrollContent(.lineDown)
        try await settle(webView, at: 40)
        // The script's page step against the core's, which it writes out for itself.
        preview.scrollContent(.pageDown)
        try await settle(webView, at: 40 + QuickViewScroll.pageStep(visibleHeight: view))
        preview.scrollContent(.end)
        try await settle(webView, at: height - view)
        preview.scrollContent(.top)
        try await settle(webView, at: 0)
    }

    /// The shape `qlmanage` gives a workbook of two sheets or more, measured on a real conversion: a
    /// page that does not scroll, its tab strip, and an iframe filling it that holds the sheet. A
    /// move that only tried the main document — or WebKit's own scroll commands, probed — leaves the
    /// sheet where it was.
    @Test("a converted workbook's sheet scrolls inside its frame, with the page around it still")
    func workbookSheetScrolls() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try QuickViewZoomFixtures.surface(width: 400, height: 400)
        preview.show(try tree.write("page.html", contents: "<p>hello</p>"), style: .rendered)
        let webView = try await QuickViewZoomFixtures.webView(in: preview)
        let surface = try #require(preview.webSurface)

        let bundle = tree.root.appendingPathComponent("book.xlsx.qlpreview", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let rows = (1...300).map { "<tr><td>Row \($0)</td></tr>" }.joined()
        try Data("<meta charset=utf-8><table>\(rows)</table>".utf8)
            .write(to: bundle.appendingPathComponent("Sheet.html"))
        let page = bundle.appendingPathComponent("Preview.html")
        try Data("""
        <html><body>
        <div style="position:absolute; top:0; left:0; right:0; bottom:25">
        <iframe id="SheetFrame" src="Sheet.html" style="border:0; width:100%; height:100%;"></iframe>
        </div><div id="tabs">Sheet 1 · Sheet 2</div>
        </body></html>
        """.utf8).write(to: page)
        surface.showConverted(page: page, bundle: bundle, allowsJavaScript: false, fitWidth: nil)

        let deadline = Date().addingTimeInterval(10)
        var sheet: WKFrameInfo?
        while sheet == nil {
            try #require(Date() < deadline, "the sheet's frame never loaded")
            for frame in surface.childFrames.reversed() {
                let height = await javaScript(
                    "return document.scrollingElement.scrollHeight",
                    in: webView,
                    frame: frame
                )
                if (height ?? 0) > 2000 { sheet = frame }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let frame = try #require(sheet)
        #expect(await javaScript(
            "return document.scrollingElement.scrollHeight - window.innerHeight",
            in: webView
        ) ?? 1 < 1)

        preview.scrollContent(.lineDown)
        try await settle(webView, frame: frame, at: 40)
        #expect(await scrollY(webView) == 0)
    }
}
