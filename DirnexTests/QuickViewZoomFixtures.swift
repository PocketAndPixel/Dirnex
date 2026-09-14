import AppKit
import CoreText
import DirnexCore
import PDFKit
import Testing
import WebKit

@testable import Dirnex

/// Surfaces, files and waits shared by the Quick View zoom suites.
@MainActor
enum QuickViewZoomFixtures {
    static var retained: [NSWindow] = []

    static func surface(width: CGFloat, height: CGFloat) throws -> QuickViewPreviewView {
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        retained.append(window)
        let content = try #require(window.contentView)
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        return preview
    }

    static func imageScrollView(
        in preview: QuickViewPreviewView
    ) async throws -> QuickViewImageScrollView {
        try await settle { preview.imageScrollView?.imageView.image != nil }
        preview.layoutSubtreeIfNeeded()
        return try #require(preview.imageScrollView)
    }

    /// A PNG of `width` × `height` pixels at 72 dpi, so its size in points is its size in pixels.
    static func png(
        width: Int,
        height: Int,
        name: String = "photo.png",
        in tree: TempDirectory
    ) throws -> URL {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: width, height: height)
        let url = tree.root.appendingPathComponent(name)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    static func webView(in preview: QuickViewPreviewView) async throws -> WKWebView {
        try await settle { preview.webSurface?.isHidden == false }
        preview.webSurface?.layoutSubtreeIfNeeded()
        return try #require(preview.webSurface?.interactiveSubtree as? WKWebView)
    }

    static func textScrollView(in preview: QuickViewPreviewView) -> NSScrollView? {
        guard let hit = preview.hitTest(NSPoint(x: 200, y: 200)) else { return nil }
        return QuickViewTextPreviewTests.enclosingTextView(of: hit)?.enclosingScrollView
    }

    static func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            try #require(Date() < deadline, "timed out waiting for the preview")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) }
    }

    /// A three-page PDF with real glyphs on each page.
    static func document() -> PDFDocument? {
        let pages = (1...3).map { number -> Data in
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 400, height: 300)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data(
            ) }
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(
                    string: "Page \(number)",
                    attributes: [.font: NSFont.systemFont(ofSize: 24)]
                )
            )
            context.textPosition = CGPoint(x: 40, y: 150)
            CTLineDraw(line, context)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
        return QuickViewPreviewView.mergedDocument(pages)
    }
}
