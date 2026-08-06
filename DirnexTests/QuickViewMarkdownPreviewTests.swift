import AppKit
import DirnexCore
import Testing
import WebKit

@testable import Dirnex

/// Quick View's second dual-style type (PLAN.md §M18 ▸ Slice 3): which files offer both renderings,
/// and where each one lands. What the page then *looks like* — the inlined images and the
/// stylesheet — is `QuickViewMarkdownPageTests`.
///
/// What is deliberately *not* here is anything about WebKit's own behaviour — whether a `#fragment`
/// click still passes `decidePolicyFor`, whether a base URL reaches a sibling image. Those are
/// claims about a framework, and they were settled where such claims can be settled: against a real
/// web view in a throwaway harness, with the numbers recorded in `QuickViewWebView` and
/// `QuickViewMarkdownImages`. What is pinned here is everything around them that a later edit could
/// quietly get wrong.
@Suite("Quick View Markdown preview")
@MainActor
struct QuickViewMarkdownPreviewTests {
    // MARK: - Routing

    @Test("the Markdown family offers both renderings")
    func recognizesMarkdown() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["README.md", "notes.markdown", "old.mdown", "older.mkd", "SHOUTING.MD"] {
            let url = try tree.write(name, contents: "# hi")
            #expect(QuickViewPreviewView.isRenderableMarkdown(url), "\(name) should be renderable")
        }
    }

    @Test("everything else keeps its single rendering")
    func leavesOtherFilesAlone() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        // `.mdx` and `.mdc` are the near misses — Markdown-ish formats this build has no parser for,
        // and a named list is what keeps them out. A conformance test would be the trap `.xhtml`
        // taught §M16, one step over.
        for name in ["notes.txt", "page.html", "letter.rtf", "photo.jpg", "app.mdx", "rule.mdc"] {
            let url = try tree.write(name, contents: "# hi")
            #expect(!QuickViewPreviewView.isRenderableMarkdown(url), "\(name) is not markdown")
        }
    }

    /// The slice's own reason for existing. The same question was spelled `isRenderableHTML` at
    /// three sites, and a second dual-style type meant finding all three by hand — the trap
    /// docs/NOTES.md names for a new VFS backend, in a different shape. One predicate, and both
    /// families reach it.
    @Test("one predicate answers for both families and for nothing else")
    func bothFamiliesOfferBothStyles() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["README.md", "page.html", "page.xhtml", "notes.markdown"] {
            let url = try tree.write(name, contents: "hi")
            #expect(QuickViewPreviewView.offersBothStyles(url), "\(name) should offer both")
        }
        for name in ["notes.txt", "photo.jpg", "letter.rtf", "page.webarchive"] {
            let url = try tree.write(name, contents: "hi")
            #expect(!QuickViewPreviewView.offersBothStyles(url), "\(name) should not")
        }
    }

    /// The `(no JavaScript)` mark rides on a *different* question, and this is the fact that makes
    /// suppressing it for Markdown expressible: a `.md` offers both styles and is not HTML. The
    /// generated page has the file's raw HTML escaped, so there is no script in it to have refused
    /// and the mark would be true and meaningless.
    @Test("a Markdown file offers both styles without being HTML")
    func markdownIsNotHTML() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("README.md", contents: "# hi")
        #expect(QuickViewPreviewView.offersBothStyles(url))
        #expect(!QuickViewPreviewView.isRenderableHTML(url))
    }

    // MARK: - Where each style lands

    @Test("a Markdown file in source style shows the text view")
    func sourceStyleUsesTheTextBackend() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("README.md", contents: "# Title\n\ntext\n")
        let preview = try QuickViewTextPreviewTests.loaded(url, style: .source)

        #expect(preview.webSurface == nil, "the web backend should not have been built")
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        #expect(QuickViewTextPreviewTests.enclosingTextView(of: hit) != nil)
    }

    @Test("a Markdown file in rendered style shows a web view that keeps the mouse")
    func renderedStyleUsesTheWebBackend() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("README.md", contents: "# Title\n\ntext\n")
        let preview = try await Self.loadedRendered(url)

        #expect(preview.textSurface?.isHidden != false, "the text backend should have stood down")
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        #expect(hit !== preview, "the click must reach the page, not be swallowed")
        #expect(Self.enclosingWebView(of: hit) != nil)
    }

    // MARK: - The read

    /// The render goes through `TextPreview`, so a `.md` gets the decoding every other text file
    /// gets — including the NUL gate that refuses a binary somebody named `.md`. That `nil` is what
    /// sends the caller back to the text backend rather than showing an empty page.
    @Test("the read decodes through TextPreview and refuses what is not text")
    func readGoesThroughTextPreview() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("README.md", contents: "# Title\n\nA [link](#title).\n")
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))
        #expect(scan.html.contains("<h1 id=\"title\">Title</h1>"))
        #expect(scan.html.contains("href=\"#title\""))
        #expect(!scan.isTruncated)

        let binary = tree.root.appendingPathComponent("binary.md")
        try Data([0x00, 0x01, 0x02, 0xFF]).write(to: binary)
        #expect(QuickViewPreviewView.MarkdownScan.read(binary) == nil)
    }

    /// A source view that stops at 4 MB is visibly mid-file; a rendered page just ends, and looks
    /// finished doing it. So the notice has to reach the page — in the *same* sentence the source
    /// view draws, since a display string that exists twice gets localized once.
    @Test("a truncated document says so, in the words the source view uses")
    func truncationReachesThePage() {
        let plain = QuickViewMarkdownStyle.document(body: "<p>x</p>")
        let cut = QuickViewMarkdownStyle.document(body: "<p>x</p>", isTruncated: true)
        #expect(!plain.contains("class=\"truncated\""))
        #expect(cut.contains("class=\"truncated\""))
        #expect(cut.contains(QuickViewTextView.truncationText))
        #expect(cut.contains("p.truncated {"))
    }

    // MARK: - Helpers
    /// compiled asynchronously on top of that (docs/NOTES.md ▸ Testing).
    private static func loadedRendered(_ url: URL) async throws -> QuickViewPreviewView {
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let content = try #require(window.contentView)
        content.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.topAnchor.constraint(equalTo: content.topAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        preview.show(url, style: .rendered)
        for _ in 0..<400 {
            if preview.webSurface?.isHidden == false { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        content.layoutSubtreeIfNeeded()
        return preview
    }

    private static func enclosingWebView(of view: NSView) -> WKWebView? {
        var candidate: NSView? = view
        while let current = candidate {
            if let webView = current as? WKWebView { return webView }
            candidate = current.superview
        }
        return nil
    }
}
