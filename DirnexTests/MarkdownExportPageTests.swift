import AppKit
import DirnexCore
import Foundation
import PDFKit
import Testing

@testable import Dirnex

/// What File ▸ Export… writes (PLAN.md §M39 ▸ Slice 12): the stylesheet, the HTML file, and the PDF
/// printed from it.
@MainActor
@Suite("Markdown export: the page and the PDF", .serialized)
struct MarkdownExportPageTests {
    // MARK: - The stylesheet

    @Test("the export stylesheet is the preview's, both appearances, one string, plus paper")
    func stylesheet() {
        let css = QuickViewMarkdownStyle.exportStylesheet(theme: .gitHub)
        #expect(css.contains("@media (prefers-color-scheme: dark)"))
        #expect(css.contains("--tok-keyword:"))
        #expect(css.contains(".tok-keyword { color: var(--tok-keyword); }"))
        #expect(css.contains("max-width: \(QuickViewMarkdownExportStyle.readingWidth)px"))
        #expect(css.contains("@media print"))
        // Nothing restyles an exported file, so it carries no marker for a repaint to find.
        #expect(!css.contains(QuickViewMarkdownStyle.syntaxStyleAttribute))
        // Every alert kind's icon, tinted for paper.
        for kind in MarkdownAlertKind.allCases {
            #expect(css.contains(
                ".markdown-alert-\(kind.rawValue) { --alert-print-icon: url(\"data:image/png;base64,"
            ))
        }
    }

    // MARK: - The HTML file

    @Test(
        "the HTML file holds what the preview drew: its image inlined, a remote one, links as written"
    )
    func htmlFile() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        try Self.png.write(to: tree.root.appendingPathComponent("pic.png"))
        let source = try tree.write("guide.md", contents: """
        # Guide

        ![local](pic.png) ![badge](https://example.com/badge.svg)

        See [the next part](other.md#part).
        """)
        let page = try await Self.html(source)
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("<title>Guide</title>"))
        #expect(page.contains(MarkdownExport.contentSecurityPolicy))
        #expect(page.contains("src=\"data:image/png;base64,"))
        #expect(page.contains("src=\"https://example.com/badge.svg\""))
        #expect(page.contains("href=\"other.md#part\""))
        #expect(page.contains("@media print"))
    }

    @Test("a page with no title of its own takes its file's stem")
    func stemTitle() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let page = try await Self.html(tree.write("notes.md", contents: "Just text."))
        #expect(page.contains("<title>notes</title>"))
    }

    @Test("an export reads the whole file, where the preview stops at 4 MB")
    func wholeFile() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let filler = String(repeating: "Lorem ipsum dolor sit amet.\n\n", count: 150_000)
        let source = try tree.write("long.md", contents: filler + "The last paragraph.\n")
        #expect(
            try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 > TextPreview.byteLimit
        )
        let page = try await Self.html(source)
        #expect(page.contains("The last paragraph."))
    }

    @Test("a file past 64 MB is refused before it is read, and a binary one has no page")
    func refusals() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let large = tree.root.appendingPathComponent("large.md")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(MarkdownExport.sourceByteLimit + 1))
        try handle.close()
        await #expect(throws: MarkdownExportFile.Failure.tooLarge) {
            _ = try await MarkdownExportFile.html(from: large, sourceName: "large.md")
        }
        let binary = tree.root.appendingPathComponent("binary.md")
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x01]).write(to: binary)
        await #expect(throws: MarkdownExportFile.Failure.notText) {
            _ = try await MarkdownExportFile.html(from: binary, sourceName: "binary.md")
        }
    }

    // MARK: - The PDF

    @Test("the PDF is pages of selectable text, light, with each alert's icon drawn on paper")
    func pdf() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let paragraphs = (1...120).map { "Paragraph \($0) of the exported page." }
        let source = try tree.write("guide.md", contents: """
        # Printed guide

        > [!NOTE]
        > Useful information.

        Inline `code` and a fence:

        ```swift
        let answer = 42
        ```

        \(paragraphs.joined(separator: "\n\n"))
        """)
        let output = tree.root.appendingPathComponent("guide.pdf")
        try await MarkdownExportFile.write(.pdf, from: source, sourceName: "guide.md", to: output)

        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount > 1)
        let page = try #require(document.page(at: 0))
        let text = page.string ?? ""
        #expect(text.contains("Printed guide"))
        #expect(document.page(at: document.pageCount - 1)?.string?.contains("Paragraph 120") == true)
        // Margins as set, on the user's own paper.
        let box = page.bounds(for: .mediaBox)
        let titleBounds = try #require(Self.bounds(of: "Printed guide", on: page))
        #expect(abs(titleBounds.minX - MarkdownExportPDF.margin) < 4)

        let picture = try #require(Self.render(page))
        // Light: almost nothing inside the margins is dark. A dark page is mostly dark.
        let content = CGRect(
            x: MarkdownExportPDF.margin,
            y: MarkdownExportPDF.margin,
            width: box.width - 2 * MarkdownExportPDF.margin,
            height: box.height - 2 * MarkdownExportPDF.margin
        )
        #expect(Self.share(of: Self.isDark, in: content, of: picture, pageHeight: box.height) < 0.1)

        // The note's icon sits left of its title. On paper a CSS mask is not applied, and the box
        // prints as a square of the title's color with the black symbol over it; the tinted icon
        // has no black at all.
        let title = QuickViewMarkdownAlerts.title(.note)
        let titleRect = try #require(Self.bounds(of: title, on: page))
        let icon = CGRect(
            x: titleRect.minX - 20,
            y: titleRect.minY - 2,
            width: 19,
            height: titleRect.height + 4
        )
        #expect(
            Self.share(of: Self.isNoteBlue, in: icon, of: picture, pageHeight: box.height) > 0.02
        )
        #expect(Self.share(of: Self.isDark, in: icon, of: picture, pageHeight: box.height) < 0.005)
    }

    // MARK: - Helpers

    /// A 1 × 1 PNG.
    static let png = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC
    """)!

    private static func html(_ url: URL) async throws -> String {
        let data = try await MarkdownExportFile.html(from: url, sourceName: url.lastPathComponent)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func bounds(of text: String, on page: PDFPage) -> CGRect? {
        guard let string = page.string else { return nil }
        let range = (string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return page.selection(for: range)?.bounds(for: page)
    }

    /// The page drawn at twice its size on white.
    private static func render(_ page: PDFPage) -> NSBitmapImageRep? {
        let box = page.bounds(for: .mediaBox)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(box.width * 2),
            pixelsHigh: Int(box.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: box.width * 2, height: box.height * 2).fill()
        context.cgContext.scaleBy(x: 2, y: 2)
        page.draw(with: .mediaBox, to: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    /// The share of `rect`'s pixels, a rect in page points, that `matches`.
    private static func share(
        of matches: (Int, Int, Int) -> Bool,
        in rect: CGRect,
        of bitmap: NSBitmapImageRep,
        pageHeight: CGFloat
    ) -> Double {
        let minX = max(0, Int(rect.minX * 2))
        let maxX = min(bitmap.pixelsWide, Int(rect.maxX * 2))
        let minY = max(0, Int((pageHeight - rect.maxY) * 2))
        let maxY = min(bitmap.pixelsHigh, Int((pageHeight - rect.minY) * 2))
        var hits = 0
        var total = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1
                if matches(
                    Int(color.redComponent * 255),
                    Int(color.greenComponent * 255),
                    Int(color.blueComponent * 255)
                ) { hits += 1 }
            }
        }
        return total == 0 ? 0 : Double(hits) / Double(total)
    }

    private static func isDark(_ red: Int, _ green: Int, _ blue: Int) -> Bool {
        red < 60 && green < 60 && blue < 60
    }

    /// GitHub's light note color, `#0969DA`, give or take the edges' blending.
    private static func isNoteBlue(_ red: Int, _ green: Int, _ blue: Int) -> Bool {
        red < 90 && (70...150).contains(green) && blue > 170
    }
}
