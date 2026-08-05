import AppKit
import Testing
import WebKit

@testable import Dirnex

/// Quick View's two renderings of an HTML file (PLAN.md §M16): which files offer both, which key
/// picks which, and that each style really lands on its own backend.
///
/// What is *not* here is the network gate, and deliberately so: "this page cannot reach the
/// network" is a claim about WebKit's behaviour, and the only honest way to check it is a real
/// server's access log — which a unit test has no business starting. That was measured against one
/// (`QuickViewWebView`'s doc comment records the numbers), and what is pinned here is everything
/// around it that a future edit could quietly get wrong.
@Suite("Quick View HTML preview")
@MainActor
struct QuickViewHTMLPreviewTests {
    // MARK: - Routing

    @Test("the HTML family offers both renderings")
    func recognizesHTML() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in ["page.html", "page.htm", "page.xhtml"] {
            let url = try tree.write(name, contents: "<p>hi</p>")
            #expect(QuickViewPreviewView.isRenderableHTML(url), "\(name) should be renderable")
        }
    }

    /// `.xhtml` is the one worth a test of its own: it is `public.xhtml`, which does **not** conform
    /// to `public.html`, so the obvious one-conformance gate would silently drop it — which is how it
    /// previewed as source with nobody noticing until §M16 probed the types.
    @Test("XHTML is included even though it does not conform to public.html")
    func includesXHTML() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("page.xhtml", contents: "<html/>")
        #expect(QuickViewPreviewView.isRenderableHTML(url))
    }

    /// The archive-of-a-page formats are the near misses: they *are* web content, and rendering one
    /// needs a `loadData` path this backend does not have, so they stay with Quick Look rather than
    /// rendering as an empty page.
    @Test("everything else keeps its single rendering")
    func leavesOtherFilesAlone() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        for name in [
            "notes.txt",
            "README.md",
            "letter.rtf",
            "photo.jpg",
            "page.mhtml",
            "x.webarchive"
        ] {
            let url = try tree.write(name, contents: "x")
            #expect(!QuickViewPreviewView.isRenderableHTML(url), "\(name) should not be renderable")
        }
    }

    // MARK: - The styles

    /// A file manager shows you the file — the milestone's headline decision, and the one thing in
    /// it a user would notice immediately if it flipped.
    @Test("source is the default style")
    func defaultsToSource() {
        #expect(QuickViewRenderStyle.default == .source)
    }

    @Test("1 and 2 select the two styles, and nothing else does")
    func digitsSelectStyles() {
        #expect(QuickViewRenderStyle.style(forDigit: "1") == .source)
        #expect(QuickViewRenderStyle.style(forDigit: "2") == .rendered)
        for key in ["0", "3", "q", "", " "] {
            #expect(QuickViewRenderStyle.style(forDigit: key) == nil, "\(key) selects nothing")
        }
    }

    /// The keys are read as *characters*, so every style has to carry one and they must not collide
    /// — a third style added with a copied `digit` would silently make one of them unreachable.
    @Test("every style has its own digit")
    func digitsAreUnique() {
        let digits = QuickViewRenderStyle.allCases.map(\.digit)
        #expect(Set(digits).count == digits.count)
    }

    // MARK: - JavaScript

    /// The default, and the reasoning behind it: a preview renders on every cursor step, so scripts
    /// left on would run because the cursor passed over a file rather than because anybody opened
    /// it. Off is therefore the shipped answer, and the switch is what buys a self-contained report
    /// rendering as itself.
    @Test("scripts are refused by default")
    func javaScriptDefaultsOff() throws {
        let suite = "dirnex.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!AppPreferences(defaults: defaults).quickViewJavaScriptEnabled)
    }

    /// The guard that would have caught this milestone's worst bug, and the reason it is written by
    /// **selector name** rather than by Swift signature.
    ///
    /// WebKit dispatches to a delegate through `respondsToSelector:`, and the first version of this
    /// backend implemented the *completion-handler* spelling of the policy callback. On a
    /// `@MainActor` class in Swift 6 that compiles, reports `surface is WKNavigationDelegate == true`
    /// — and is **never emitted as an Objective-C method at all**: the class's whole method list was
    /// `initWithFrame:`, `initWithCoder:` and `.cxx_destruct`. So the callback never ran, and with it
    /// went the rule that a link cannot navigate the preview somewhere else. The `async` variant is
    /// the witness Swift 6 recognizes, and it emits the requirement's own selector.
    @Test("the web view really answers the per-navigation policy callback")
    func answersThePolicyCallback() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("page.html", contents: "<p>hi</p>")
        let preview = try Self.loadedRendered(url)
        let surface = try #require(preview.webSurface)
        // Spelled out, not `#selector(WKNavigationDelegate.webView(_:decidePolicyFor:preferences:
        // decisionHandler:))`: that expression resolves against the *protocol*, so it keeps naming
        // the right selector even when the class has stopped implementing it — which is exactly the
        // state this test exists to detect.
        #expect(surface.responds(
            to: Selector("webView:decidePolicyForNavigationAction:preferences:decisionHandler:")
        ))
    }

    // MARK: - Where each style lands

    @Test("an HTML file in source style shows the text view")
    func sourceStyleUsesTheTextBackend() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("page.html", contents: "<p>hi</p>")
        let preview = try QuickViewTextPreviewTests.loaded(url, style: .source)

        #expect(preview.webSurface == nil, "the web backend should not have been built")
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        #expect(QuickViewTextPreviewTests.enclosingTextView(of: hit) != nil)
    }

    /// The whole of the milestone in one assertion: the rendered page has to *keep the mouse*, since
    /// a surface that swallows the click is a page that cannot be scrolled — which is what Quick
    /// Look's HTML preview was.
    @Test("an HTML file in rendered style shows a web view that keeps the mouse")
    func renderedStyleUsesTheWebBackend() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("page.html", contents: "<p>hi</p>")
        let preview = try Self.loadedRendered(url)

        #expect(preview.textSurface?.isHidden != false, "the text backend should have stood down")
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        #expect(hit !== preview, "the click must reach the page, not be swallowed")
        #expect(Self.enclosingWebView(of: hit) != nil)
    }

    /// Mirrors the text view's own test. The Esc monitor stands aside for every `NSText`, so a
    /// backend that is *not* one keeps Esc meaning "close the preview" — which is what a user who
    /// clicked into a page to scroll it expects.
    @Test("the preview's web view is not an NSText the Esc monitor would defer to")
    func escapeMonitorDoesNotMistakeTheWebView() {
        #expect(!(QuickViewDocumentWebView() is NSText))
    }

    // MARK: - Helpers

    /// A surface showing `url` as a rendered page. Slower than the text helper on purpose: the web
    /// backend is built asynchronously, because the block-remote content rules have to compile
    /// before there is anything safe to build.
    private static func loadedRendered(_ url: URL) throws -> QuickViewPreviewView {
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
        for _ in 0..<300 where preview.webSurface == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // And a little longer for the page itself, so the hit test lands on a laid-out view.
        for _ in 0..<50 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            content.layoutSubtreeIfNeeded()
        }
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
