import AppKit
import CoreText
import DirnexCore
import PDFKit
import Testing
import WebKit

@testable import Dirnex

/// ⌘+, ⌘− and ⌘0 on a Quick View preview (2026-09-14): the menu that carries the keys, and what a step
/// does to each backend that zooms. The ladder itself is `DirnexCore`'s (`QuickViewZoom`).
@Suite("Quick View zoom keys")
@MainActor
struct QuickViewZoomKeysTests {
    // MARK: - The menu

    private static let zoomIn = #selector(BrowserWindowController.zoomInQuickView(_:))
    private static let zoomOut = #selector(BrowserWindowController.zoomOutQuickView(_:))
    private static let reset = #selector(BrowserWindowController.resetQuickViewZoom(_:))

    @Test("the three commands reach the window's actions through the built menu, on ⌘+, ⌘− and ⌘0")
    func menuCarriesTheKeys() throws {
        #expect(CommandBinding.selector(for: "view.quickViewZoomIn") == Self.zoomIn)
        #expect(CommandBinding.selector(for: "view.quickViewZoomOut") == Self.zoomOut)
        #expect(CommandBinding.selector(for: "view.quickViewResetZoom") == Self.reset)

        // A store of our own, so the developer's rebindings cannot change what is being asserted.
        let items = Self.flatten(
            MainMenuBuilder.build(bindings: KeyBindingStore(defaults: ScratchDefaults.fresh()))
        )
        let zoomInItems = items.filter { $0.action == Self.zoomIn }
        let visible = try #require(zoomInItems.first { !$0.isHidden })
        #expect(visible.keyEquivalent == "+")
        #expect(visible.keyEquivalentModifierMask == .command)
        let zoomOut = try #require(items.first { $0.action == Self.zoomOut })
        #expect(zoomOut.keyEquivalent == "-" && zoomOut.keyEquivalentModifierMask == .command)
        let reset = try #require(items.first { $0.action == Self.reset })
        #expect(reset.keyEquivalent == "0" && reset.keyEquivalentModifierMask == .command)
    }

    /// Measured before this was written: an item bound to "+" does not fire for a plain ⌘=, which is
    /// how ⌘+ is typed on a US keyboard. The hidden alias is what makes the key work as pressed.
    @Test("Zoom In also carries a hidden ⌘= alias, so the unshifted key works")
    func zoomInHasAnUnshiftedAlias() throws {
        let items = Self.flatten(
            MainMenuBuilder.build(bindings: KeyBindingStore(defaults: ScratchDefaults.fresh()))
        )
        let alias = try #require(items.first { $0.action == Self.zoomIn && $0.isHidden })
        #expect(alias.keyEquivalent == "=")
        #expect(alias.keyEquivalentModifierMask == .command)
        #expect(alias.allowsKeyEquivalentWhenHidden)
    }

    @Test("the alias goes away when Zoom In is rebound, or when something else takes ⌘=")
    func aliasFollowsTheBinding() {
        let rebound = KeyBindingStore(defaults: ScratchDefaults.fresh("rebound"))
        rebound.setShortcut(
            CommandShortcut(key: "i", modifiers: [.command, .option]),
            for: "view.quickViewZoomIn"
        )
        #expect(MainMenuBuilder.keyAliasItem(for: "view.quickViewZoomIn", bindings: rebound) == nil)

        let claimed = KeyBindingStore(defaults: ScratchDefaults.fresh("claimed"))
        claimed.setShortcut(CommandShortcut(key: "=", modifiers: .command), for: "view.toggleHidden")
        #expect(MainMenuBuilder.keyAliasItem(for: "view.quickViewZoomIn", bindings: claimed) == nil)

        // The narrowness control: the default binding does get one.
        let untouched = KeyBindingStore(defaults: ScratchDefaults.fresh("untouched"))
        #expect(
            MainMenuBuilder.keyAliasItem(for: "view.quickViewZoomIn", bindings: untouched) != nil
        )
        // And only Zoom In has an unshifted spelling to add.
        #expect(
            MainMenuBuilder.keyAliasItem(for: "view.quickViewZoomOut", bindings: untouched) == nil
        )
    }

    // MARK: - Text

    @Test("text zooms along the ladder, stops at its end, and ⌘0 goes back")
    func textZooms() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try await QuickViewTextPreviewTests.loaded(
            tree.write("notes.txt", contents: "plain\n")
        )
        let scrollView = try #require(Self.textScrollView(in: preview))
        #expect(!preview.canResetZoom)

        preview.zoom(.larger)
        preview.zoom(.larger)
        #expect(abs(scrollView.magnification - 1.25) < 0.001)
        #expect(preview.canResetZoom)

        preview.resetZoom()
        #expect(abs(scrollView.magnification - 1) < 0.001)
        #expect(!preview.canResetZoom)

        while preview.canZoom(.smaller) {
            preview.zoom(.smaller)
        }
        #expect(abs(scrollView.magnification - 0.25) < 0.001)
        #expect(preview.canZoom(.larger))
    }

    // MARK: - PDF

    @Test("a fitted PDF zooms relative to its fit, and ⌘0 hands it back to fitting")
    func fittedPDFZooms() throws {
        let preview = try Self.surface(width: 900, height: 600)
        preview.showPDFDocument(Self.document(), fitsWidth: true)
        let pdfView = try #require(preview.pdfView)
        let fit = pdfView.scaleFactorForSizeToFit

        preview.zoom(.larger)
        #expect(!pdfView.autoScales)
        #expect(abs(pdfView.scaleFactor - fit * 1.1) < 0.001)
        #expect(preview.canResetZoom)

        preview.resetZoom()
        #expect(pdfView.autoScales)
        #expect(!preview.canResetZoom)
    }

    @Test("a sheet's PDF zooms from its own size, and ⌘0 goes back to it")
    func unfittedPDFZooms() throws {
        let preview = try Self.surface(width: 900, height: 600)
        preview.showPDFDocument(Self.document(), fitsWidth: false)
        let pdfView = try #require(preview.pdfView)

        preview.zoom(.smaller)
        #expect(abs(pdfView.scaleFactor - 0.9) < 0.001)
        preview.resetZoom()
        #expect(abs(pdfView.scaleFactor - 1) < 0.001)
        #expect(!pdfView.autoScales)
    }

    // MARK: - Web

    @Test("a rendered page zooms by page zoom, and the next file starts back at 100 %")
    func renderedPageZooms() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try Self.surface(width: 400, height: 400)
        preview.show(try tree.write("page.html", contents: "<p>hello</p>"), style: .rendered)
        let webView = try await Self.webView(in: preview)

        preview.zoom(.larger)
        #expect(abs(webView.pageZoom - 1.1) < 0.001)
        preview.resetZoom()
        #expect(abs(webView.pageZoom - 1) < 0.001)

        preview.zoom(.larger)
        preview.show(try tree.write("other.html", contents: "<p>next</p>"), style: .rendered)
        try await Self.settle { abs(webView.pageZoom - 1) < 0.001 }
    }

    /// The level multiplies the page's starting size rather than replacing it, or ⌘+ on a Word page
    /// fitted at 200 % would shrink it to 110 %.
    @Test("a converted page's zoom is a multiple of its fit, not a replacement for it")
    func convertedPageZoomsFromItsFit() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let preview = try Self.surface(width: 400, height: 400)
        preview.show(try tree.write("page.html", contents: "<p>hello</p>"), style: .rendered)
        let webView = try await Self.webView(in: preview)
        let surface = try #require(preview.webSurface)
        let bundle = tree.root.appendingPathComponent("doc.qlpreview", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let page = bundle.appendingPathComponent("Preview.html")
        try Data("<p>page</p>".utf8).write(to: page)

        // A 300-point page on a 400-point surface fits at 400 / 300.
        surface.showConverted(page: page, bundle: bundle, allowsJavaScript: false, fitWidth: 300)
        let fit = surface.bounds.width / 300
        #expect(abs(webView.pageZoom - fit) < 0.01)
        preview.zoom(.larger)
        #expect(abs(webView.pageZoom - fit * 1.1) < 0.01)
    }

    // MARK: - What does not zoom

    @Test("a photograph offers no zoom, so the keys are disabled")
    func imageDoesNotZoom() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = tree.root.appendingPathComponent("dot.png")
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        let preview = try Self.surface(width: 400, height: 400)
        preview.show(url, style: .source)
        try await Self.settle { preview.imageView?.image != nil }

        #expect(!preview.canZoom(.larger))
        #expect(!preview.canZoom(.smaller))
        #expect(!preview.canResetZoom)
    }

    // MARK: - Helpers

    private static var retained: [NSWindow] = []

    private static func surface(width: CGFloat, height: CGFloat) throws -> QuickViewPreviewView {
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

    private static func webView(in preview: QuickViewPreviewView) async throws -> WKWebView {
        try await settle { preview.webSurface?.isHidden == false }
        preview.webSurface?.layoutSubtreeIfNeeded()
        return try #require(preview.webSurface?.interactiveSubtree as? WKWebView)
    }

    private static func textScrollView(in preview: QuickViewPreviewView) -> NSScrollView? {
        guard let hit = preview.hitTest(NSPoint(x: 200, y: 200)) else { return nil }
        return QuickViewTextPreviewTests.enclosingTextView(of: hit)?.enclosingScrollView
    }

    private static func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            try #require(Date() < deadline, "timed out waiting for the preview")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func flatten(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(flatten) ?? []) }
    }

    /// A three-page PDF with real glyphs on each page.
    private static func document() -> PDFDocument? {
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
