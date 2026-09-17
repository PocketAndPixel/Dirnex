import AppKit
import DirnexCore
import Testing
import WebKit

@testable import Dirnex

/// Finding text in Quick View's rendered page (2026-09-17). Which text matches is `DirnexCore`'s and
/// tested there (`TextFindMatchesTests`); what is left is what this surface does with it — that the
/// page's text is read at all, that the offsets it answers address the right words, what is drawn on
/// them, and that a new page forgets it.
///
/// The highlights are the CSS Custom Highlight API, which paints without touching the DOM, so they
/// cannot be read back out of the markup. What *is* readable — and is what these assert — is the
/// registry: how many ranges each highlight holds and what text they cover, asked of the page in the
/// same isolated world the find runs in.
@Suite("Quick View page find", .serialized)
@MainActor
struct QuickViewPageFindTests {
    private typealias Typing = QuickViewTableFilterFixtures

    private static let page = """
    <html><body>
    <p>alpha Beta gamma</p>
    <p>beta delta</p>
    <script>var hidden = 'beta in a script';</script>
    <p style="display:none">beta while hidden</p>
    <p>BETA at the end</p>
    </body></html>
    """

    @Test("typing finds every occurrence in the page, ignoring case, the first one current")
    func findsEveryOccurrence() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        // Three: the two paragraphs and the last one. The script's and the hidden paragraph's are
        // not the page's text and must not be counted.
        #expect(surface.find.matches?.count == 3)
        #expect(surface.find.current == 0)
        #expect(surface.filterBar.countLabel.stringValue.contains("3"))
        #expect(surface.filterBar.columnPicker.isHidden)
    }

    /// The assertion that the offsets are *right* rather than merely numerous: what the highlighted
    /// ranges cover, read back from the page, has to be the word that was typed.
    @Test("the offsets address the words themselves, and the current one is highlighted apart")
    func highlightsCoverTheMatches() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        let drawn = try await QuickViewPageFindFixtures.settled(in: surface) { $0.current == ["Beta"] }
        #expect(drawn.current == ["Beta"])
        #expect(drawn.others == ["beta", "BETA"])
    }

    @Test("stepping moves the current highlight and wraps past either end")
    func steppingMovesTheCurrentHighlight() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        let down = #selector(NSResponder.moveDown(_:))
        try Typing.editor(of: surface).doCommand(by: down)
        #expect(surface.find.current == 1)
        var drawn = try await QuickViewPageFindFixtures.settled(in: surface) { $0.current == ["beta"] }
        #expect(drawn.current == ["beta"])
        #expect(drawn.others == ["Beta", "BETA"])

        try Typing.editor(of: surface).doCommand(by: down)
        try Typing.editor(of: surface).doCommand(by: down)
        #expect(surface.find.current == 0)
        drawn = try await QuickViewPageFindFixtures.settled(in: surface) { $0.current == ["Beta"] }
        #expect(drawn.current == ["Beta"])
    }

    @Test("clearing the text takes every highlight off and leaves the page as it was rendered")
    func clearingRemovesTheHighlights() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(
            try await QuickViewPageFindFixtures.settled(in: surface) { $0.total == 3 }.total == 3
        )
        try await Typing.type("", into: surface)
        let drawn = try await QuickViewPageFindFixtures.settled(in: surface) { $0.total == 0 }
        #expect(drawn.total == 0)
        #expect(surface.find.matches == nil)
        // The one thing the find adds to the document goes with them.
        let style = try await QuickViewPageFindFixtures.evaluate(
            "return document.getElementById('\(QuickViewPageFindScript.styleID)') !== null",
            in: surface
        )
        #expect(style as? Bool == false)
    }

    @Test("a word found nowhere says so and highlights nothing")
    func noMatches() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("zzzznotthere", into: surface)
        #expect(surface.find.matches?.isEmpty == true)
        #expect(
            try await QuickViewPageFindFixtures.settled(in: surface) { $0.total == 0 }.total == 0
        )
        #expect(!surface.filterBar.countLabel.stringValue.isEmpty)
    }

    /// The rule the whole surface is built around: an HTML file has a **source** style one keystroke
    /// away, which finds by `DirnexCore`'s rule, so the rendered page must find by it too. A page
    /// whose text differs from its markup is what makes the assertion mean something — `beta` occurs
    /// three times in the *text* and four times in the *source*, so a find that had leaked into the
    /// markup would count differently.
    @Test("the page is searched as text, not as markup")
    func searchesTextRatherThanMarkup() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(
            "<html><body><p class=\"beta\">alpha</p><p>beta</p></body></html>"
        )
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.find.matches?.count == 1)
        let drawn = try await QuickViewPageFindFixtures.settled(in: surface) { $0.current == ["beta"] }
        #expect(drawn.current == ["beta"])
    }

    /// A match whose letters are split across elements is one match in the page's text, which is
    /// what reading the *text nodes joined* buys over matching them one at a time.
    @Test("a match split across elements is still found, and highlighted across both")
    func matchAcrossElements() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(
            "<html><body><p>be<b>t</b>a and more</p></body></html>"
        )
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.find.matches?.count == 1)
        let drawn = try await QuickViewPageFindFixtures.settled(in: surface) { $0.current == ["beta"] }
        #expect(drawn.current == ["beta"])
    }

    /// Which *engine* is doing the matching, pinned rather than assumed.
    ///
    /// `WKWebView.find` was the other candidate and folds accents, ligatures and ß against ss —
    /// probed, it matches `cafe` against `café`. `FilterQuery` counts accents, which is how every
    /// other Quick View surface matches, so the rendered page must count them too. Reached for
    /// `findString` or `find` instead and this is the test that goes red.
    /// The charset is declared, and it has to be: probed, WebKit decodes an HTML file that declares
    /// none as **windows-1252**, so an undeclared UTF-8 page really does say `cafÃ©` and finding no
    /// `café` in it is the right answer. The find searches what the page *shows*.
    @Test("accents count, as they do everywhere else the filter bar matches")
    func accentsCount() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(
            "<html><head><meta charset=\"utf-8\"></head><body><p>café society</p></body></html>"
        )
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("cafe", into: surface)
        #expect(surface.find.matches?.isEmpty == true)
        try await Typing.type("café", into: surface)
        #expect(surface.find.matches?.count == 1)
    }

    @Test("a new page forgets the matches and puts the bar away")
    func newPageForgets() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(surface.find.matches != nil)

        let next = try fixture.tree.write(
            "other.html",
            contents: "<html><body><p>nothing</p></body></html>"
        )
        fixture.preview.show(next, style: .rendered)
        #expect(surface.find.matches == nil)
        #expect(surface.find.current == nil)
        #expect(surface.filterBar.isHidden)
        #expect(surface.filterBar.query.isEmpty)
    }

    /// The same page loaded again — which is what changing the JavaScript preference does — rebuilds
    /// the DOM and throws every highlight away with it. The matches are still the right ones, so they
    /// go back on rather than the user having to retype.
    @Test("a reload of the same page draws the highlights again")
    func reloadRedrawsTheHighlights() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        #expect(
            try await QuickViewPageFindFixtures.settled(in: surface) { $0.total == 3 }.total == 3
        )

        // A marker in the isolated world, which a reload takes with the document it belongs to. The
        // reload is asynchronous, so without waiting for it to *land* the read below sees the
        // highlights still up from before it — which is a test that passes with the redraw deleted,
        // as the control on this one proved before this wait was added.
        try await QuickViewPageFindFixtures.evaluate(
            "window.dirnexReloadProbe = 1; return true",
            in: surface
        )
        surface.reloadPage()
        for _ in 0..<400 {
            try? await Task.sleep(for: .milliseconds(10))
            let marker = try await QuickViewPageFindFixtures.evaluate(
                "return typeof window.dirnexReloadProbe",
                in: surface
            )
            if marker as? String == "undefined" { break }
        }
        // The matches survive the reload; the highlights have to be drawn again by `didFinish`.
        #expect(surface.find.matches?.count == 3)
        let drawn = try await QuickViewPageFindFixtures.settled(in: surface) { $0.current == ["Beta"] }
        #expect(drawn.current == ["Beta"])
        #expect(drawn.others == ["beta", "BETA"])
    }

    /// The repaint nudge puts the page back.
    ///
    /// What the nudge itself fixes — a highlight that goes on being painted after it is removed — no
    /// test here can see: the registry was always right and the pixels were stale, so every
    /// assertion in this suite passed against the broken build and only the running app showed it
    /// (docs/NOTES.md ▸ AppKit). What *is* assertable is the hazard the fix introduces: it dims the
    /// root for one frame, and a page left at that opacity would be a preview quietly drawn wrong.
    @Test("the repaint nudge does not leave the page dimmed")
    func repaintNudgeIsPutBack() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        let surface = fixture.surface
        try await Typing.type("beta", into: surface)
        _ = try await QuickViewPageFindFixtures.settled(in: surface) { $0.total == 3 }
        // Past the frame the nudge is taken off on.
        try? await Task.sleep(for: .milliseconds(200))
        let opacity = try await QuickViewPageFindFixtures.evaluate(
            "return document.documentElement.style.opacity",
            in: surface
        )
        let restored = try #require(opacity as? String)
        #expect(restored.isEmpty)
    }

    @Test("View ▸ Filter offers a rendered page, and its bar keeps the mouse")
    func theCommandReachesTheSurface() async throws {
        let fixture = try await QuickViewPageFindFixtures.page(Self.page)
        defer { fixture.cleanup() }
        #expect(fixture.preview.filterableSurface === fixture.surface)
        // The bar is exempt from the surface's mouse swallow only while it is up, so the exemption
        // is exactly as large as the affordance.
        fixture.surface.beginFiltering()
        fixture.preview.layoutSubtreeIfNeeded()
        let inBar = NSPoint(x: 60, y: fixture.preview.bounds.maxY - 15)
        let hit = try #require(fixture.preview.hitTest(inBar))
        #expect(hit.isDescendant(of: fixture.surface.filterBar))
    }
}

@MainActor
enum QuickViewPageFindFixtures {
    struct Fixture {
        let preview: QuickViewPreviewView
        let surface: QuickViewWebView
        let tree: TempDirectory

        func cleanup() {
            tree.cleanup()
        }
    }

    /// Every fixture window, kept for the life of the process — tearing one down while AppKit is
    /// still settling it crashes a later test (docs/NOTES.md ▸ Testing).
    private static var windows: [NSWindow] = []

    /// A surface showing `html` as a rendered page, awaited until the web backend has the page.
    ///
    /// Slower than the text helper on purpose: the backend is built asynchronously, because the
    /// block-remote content rules have to compile before there is anything safe to build.
    static func page(_ html: String, function: String = #function) async throws -> Fixture {
        let tree = try TempDirectory()
        let url = try tree.write("page.html", contents: html)
        let preview = QuickViewPreviewView(backingColor: .textBackgroundColor, header: .none)
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
        preview.show(url, style: .rendered)
        // Polled with `Task.sleep` rather than spun: a run-loop spin never lets the rule
        // compilation's continuation land (docs/NOTES.md ▸ Testing).
        for _ in 0..<1200 {
            if preview.webSurface?.isHidden == false { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let surface = try #require(preview.webSurface)
        // And until the page itself has text, since everything here reads it.
        for _ in 0..<600 {
            if await !surface.findableText().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        container.layoutSubtreeIfNeeded()
        _ = function
        return Fixture(preview: preview, surface: surface, tree: tree)
    }

    /// What each highlight actually covers, read out of the page's own registry — the only place a
    /// CSS Custom Highlight can be read back, since it draws without touching the DOM.
    struct Drawn {
        let current: [String]
        let others: [String]
        var total: Int { current.count + others.count }
    }

    /// What the page is drawing, once `condition` holds of it — and after a bounded wait whatever it
    /// holds then, so a wrong answer fails on the caller's assertion rather than timing out.
    ///
    /// Each caller says what it is waiting *for*, because the totals do not move for a step: ↓ leaves
    /// three highlights and changes which of them is current, so a wait on the count is satisfied by
    /// the draw before the step and reads the old current match (docs/NOTES.md ▸ Testing — ask what
    /// the predicate would be true of in the broken build).
    ///
    /// One poll, not a poll inside a poll: `highlighted` used to settle on its own *and* be looped
    /// over by callers, which is quadratic — a single failing assertion became 80 000 round trips and
    /// a run that had to be killed. A read a caller may loop over has to be a plain read.
    static func settled(
        in surface: QuickViewWebView,
        until condition: (Drawn) -> Bool
    ) async throws -> Drawn {
        var drawn = try await highlighted(in: surface)
        for _ in 0..<200 where !condition(drawn) {
            try? await Task.sleep(for: .milliseconds(10))
            drawn = try await highlighted(in: surface)
        }
        return drawn
    }

    /// What the page is drawing right now — the only place a CSS Custom Highlight can be read back,
    /// since it draws without touching the DOM.
    static func highlighted(in surface: QuickViewWebView) async throws -> Drawn {
        let read = """
        function texts(name) {
          if (typeof CSS === 'undefined' || !CSS.highlights) { return []; }
          const highlight = CSS.highlights.get(name);
          if (!highlight) { return []; }
          const found = [];
          for (const range of highlight) { found.push(range.toString()); }
          return found;
        }
        return {
          current: texts('\(QuickViewPageFindScript.currentName)'),
          others: texts('\(QuickViewPageFindScript.allName)')
        };
        """
        let value = try await evaluate(read, in: surface)
        let dictionary = value as? [String: Any] ?? [:]
        return Drawn(
            current: dictionary["current"] as? [String] ?? [],
            others: dictionary["others"] as? [String] ?? []
        )
    }

    @discardableResult
    static func evaluate(_ script: String, in surface: QuickViewWebView) async throws -> Any? {
        try await surface.webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
    }
}
