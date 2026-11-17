import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// RTF as the fifth dual-style family (PLAN.md §M39 ▸ Slice 3): which files offer a source beside the
/// document, which style they open in and remember, and what each style puts on screen. The coloring
/// itself is `DirnexCore`'s (`SyntaxRTFScanner`) and is tested there.
@Suite("Quick View RTF source")
@MainActor
struct QuickViewRichTextSourceTests {
    static let letter = #"{\rtf1\ansi Plain {\b Bold} text}"#

    // MARK: - Routing

    @Test("an RTF file offers both styles, and an RTFD, OpenDocument and Word file do not")
    func routesRichText() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["letter.rtf", "LETTER.RTF"] {
            let url = try tree.write(name, contents: Self.letter)
            #expect(QuickViewPreviewView.dualStyleKind(of: url) == .richText, "\(name)")
            #expect(QuickViewPreviewView.isRichTextDocument(url), "\(name)")
        }
        let package = try Self.writeRTFD(in: tree)
        #expect(QuickViewPreviewView.isRichTextDocument(package))
        #expect(QuickViewPreviewView.dualStyleKind(of: package) == nil)
        for name in ["essay.odt", "letter.docx", "notes.txt", "page.html"] {
            let url = try tree.write(name, contents: "x")
            #expect(QuickViewPreviewView.dualStyleKind(of: url) != .richText, "\(name)")
        }
    }

    /// The opposite of a page's default, which is why it is remembered apart.
    @Test("RTF opens as its document, remembers its choice apart, and calls it Document")
    func stylesArePerFamily() {
        let defaults = ScratchDefaults.fresh()
        let preferences = AppPreferences(defaults: defaults)
        #expect(preferences.quickViewRenderStyle(for: .richText) == .rendered)
        #expect(preferences.quickViewRenderStyle(for: .page) == .source)

        preferences.setQuickViewRenderStyle(.source, for: .richText)
        preferences.setQuickViewRenderStyle(.rendered, for: .page)
        #expect(preferences.quickViewRenderStyle(for: .richText) == .source)
        #expect(AppPreferences(defaults: defaults).quickViewRenderStyle(for: .richText) == .source)
        #expect(AppPreferences(defaults: defaults).quickViewRenderStyle(for: .page) == .rendered)

        let document = QuickViewRenderStyle.rendered.headerLabel(for: .richText)
        #expect(document != QuickViewRenderStyle.rendered.headerLabel(for: .page))
        #expect(QuickViewRenderStyle.source.headerLabel(for: .richText)
            == QuickViewRenderStyle.source.headerLabel(for: .page))
    }

    // MARK: - What reaches the screen

    @Test("the source is the file's own text, colored, and not mapped like a document")
    func sourceReachesTheScreen() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("letter.rtf", contents: Self.letter)
        let preview = try await QuickViewTextPreviewTests.loaded(url, style: .source)
        let textView = try Self.textView(in: preview)
        try await Self.settle { textView.string == Self.letter }

        #expect(!textView.usesAdaptiveColorMappingForDarkAppearance)
        let storage = try #require(textView.textStorage)
        try #require(storage.length > 12)
        // `\rtf` at 1, its parameter at 5, `Plain` at 12.
        #expect(Self.color(at: 1, in: storage) == SyntaxTheme.color(for: .keyword))
        #expect(Self.color(at: 5, in: storage) == SyntaxTheme.color(for: .number))
        #expect(Self.color(at: 12, in: storage) == NSColor.textColor)
    }

    /// The same file in both styles, on one surface: the guard that skips re-showing the file already
    /// on screen has to let a change of style through, which is the whole of what `1` and `2` do.
    @Test("switching style on the same file swaps the document and its source")
    func switchingStyles() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("letter.rtf", contents: Self.letter)
        let preview = try await QuickViewTextPreviewTests.loaded(url, style: .rendered)
        let textView = try Self.textView(in: preview)
        try await Self.settle { textView.string == "Plain Bold text" }
        #expect(textView.usesAdaptiveColorMappingForDarkAppearance)

        preview.show(url, style: .source)
        try await Self.settle { textView.string == Self.letter }
        preview.show(url, style: .rendered)
        try await Self.settle { textView.string == "Plain Bold text" }
    }

    /// An RTFD is a folder of a `TXT.rtf` and its attachments, so it has no single text to show; the
    /// source style a window hands over for it is ignored, as it is for any one-style file.
    @Test("an RTFD keeps its one style: the document, whatever style is asked for")
    func rtfdKeepsOneStyle() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let package = try Self.writeRTFD(in: tree)
        let preview = try await QuickViewTextPreviewTests.loaded(package, style: .source)
        let textView = try Self.textView(in: preview)
        try await Self.settle { textView.string == "Packaged" }
        #expect(textView.usesAdaptiveColorMappingForDarkAppearance)
    }

    // MARK: - Helpers

    /// An RTFD package written by AppKit itself, so its layout is the real one.
    private static func writeRTFD(in tree: TempDirectory) throws -> URL {
        let package = tree.root.appendingPathComponent("notes.rtfd", isDirectory: true)
        let text = NSAttributedString(string: "Packaged")
        let wrapper = try text.fileWrapper(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        try wrapper.write(to: package, options: .atomic, originalContentsURL: nil)
        return package
    }

    private static func textView(in preview: QuickViewPreviewView) throws -> NSTextView {
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        return try #require(QuickViewTextPreviewTests.enclosingTextView(of: hit))
    }

    private static func color(at index: Int, in storage: NSTextStorage) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    /// Wait for an asynchronous read to land (docs/NOTES.md ▸ Testing).
    private static func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            try #require(Date() < deadline, "timed out waiting for the preview to load")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
