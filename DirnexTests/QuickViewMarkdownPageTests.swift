import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The *page* half of Quick View's Markdown backend (PLAN.md §M18 ▸ Slice 3): the bytes an image
/// arrives as, and the stylesheet that turns `DirnexCore`'s fragment into a document.
///
/// A separate suite from `QuickViewMarkdownPreviewTests`, which is about *routing* — which files
/// offer two renderings and where each one lands. Split by concept rather than to shave lines, per
/// docs/NOTES.md: what is on screen and what decided to put it there are two subjects, and the
/// helpers below (a colour parser, two real PNGs) belong to exactly one of them.
///
/// What is deliberately *not* here is WebKit's own behaviour — whether a base URL reaches a sibling
/// image, whether `prefers-color-scheme` follows the view. Those are claims about a framework and
/// were settled against a real web view in a throwaway harness, with the numbers recorded in
/// `QuickViewMarkdownImages` and `QuickViewMarkdownStyle`.
@Suite("Quick View Markdown page")
@MainActor
struct QuickViewMarkdownPageTests {
    // MARK: - Images

    /// A generated page has **no filesystem access** — measured, `loadHTMLString(_:baseURL:)` grants
    /// none — so the only way `![](img/x.png)` draws anything is the app reading the bytes and
    /// handing them over inline. This is that, end to end through the real render.
    @Test("an image beside the file is carried into the page as data:")
    func imagesAreInlined() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        try FileManager.default.createDirectory(
            at: tree.root.appendingPathComponent("img"),
            withIntermediateDirectories: true
        )
        try Self.pngBytes.write(to: tree.root.appendingPathComponent("img/red.png"))
        let url = try tree.write("doc.md", contents: "![a red square](img/red.png)\n")

        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))
        #expect(scan.html.contains("src=\"data:image/png;base64,"))
        #expect(!scan.html.contains("src=\"img/red.png\""))
    }

    /// The containment rule, which is the whole security surface of the inliner: a previewed
    /// document may hand the page files from **its own directory** and nothing else — the same
    /// scope `loadFileURL` grants a saved HTML page, so both backends are one sentence.
    ///
    /// Each of these is a way out of a directory that a plausible implementation misses: `..`
    /// (which a textual `standardized` folds away without checking), an absolute path, a symlink
    /// pointing outside, and a remote URL that is not ours to fetch at all.
    @Test("a document cannot inline anything outside its own directory")
    func inliningIsContained() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let outside = tree.root.appendingPathComponent("outside", isDirectory: true)
        let inside = tree.root.appendingPathComponent("doc", isDirectory: true)
        for directory in [outside, inside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // Two *different* images, so "the secret never reached the page" is a claim about the
        // secret's own bytes. Written with the same bytes on both sides, the search would find the
        // permitted image's base64 and pass no matter what the inliner did.
        try Self.secretPNGBytes.write(to: outside.appendingPathComponent("secret.png"))
        try Self.pngBytes.write(to: inside.appendingPathComponent("ok.png"))
        try FileManager.default.createSymbolicLink(
            at: inside.appendingPathComponent("link.png"),
            withDestinationURL: outside.appendingPathComponent("secret.png")
        )
        let document = inside.appendingPathComponent("doc.md")
        let escapes = [
            "../outside/secret.png",
            outside.appendingPathComponent("secret.png").path,
            "link.png",
            "https://example.com/tracker.png"
        ]
        try Data("""
        ![ok](ok.png)
        \(escapes.map { "![no](\($0))" }.joined(separator: "\n\n"))
        """.utf8).write(to: document)

        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(document))
        // Exactly one image was carried in: the one that lives beside the document.
        #expect(scan.html.components(separatedBy: "data:image").count - 1 == 1)
        #expect(scan.html.contains(Self.pngBytes.base64EncodedString()))
        // And the file the document was not allowed to read is nowhere in the page, by its own
        // bytes rather than by its name.
        #expect(!scan.html.contains(Self.secretPNGBytes.base64EncodedString()))
        // The refused ones keep their source as written, so a remote image is still just a remote
        // image the content rules will block — the same answer HTML has always given.
        #expect(scan.html.contains("https://example.com/tracker.png"))
    }

    /// A `.zip` renamed `.png` is not an image, and a page must not be handed one as if it were.
    @Test("only image types are inlined")
    func onlyImagesAreInlined() throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        _ = try tree.write("notes.txt", contents: "not an image")
        let url = try tree.write("doc.md", contents: "![x](notes.txt)\n")
        let scan = try #require(QuickViewPreviewView.MarkdownScan.read(url))
        #expect(!scan.html.contains("data:"))
        #expect(scan.html.contains("src=\"notes.txt\""))
    }

    // MARK: - The stylesheet

    /// The coupling this slice made compiler-visible. The class a coloured run carries is the
    /// **core's** name, published for exactly this reason: a stylesheet that spelled them a second
    /// time would drift, and the failure is a fence rendering in flat text with every automated
    /// signal green.
    @Test("every class the renderer can emit has a colour rule")
    func stylesheetNamesEveryTokenClass() {
        let fragment = MarkdownDocument.render("""
        ```swift
        // a comment
        let answer = 42
        ```
        """).html
        let emitted = Self.tokenClasses(in: fragment)
        #expect(!emitted.isEmpty, "the fence should have produced coloured spans")

        let page = QuickViewMarkdownStyle.document(body: fragment)
        // What this document happened to produce, and then the whole vocabulary — so a kind that no
        // snippet here exercises still has to be styled.
        for name in emitted.union(Self.everyTokenClass) {
            #expect(page.contains(".\(name) {"), "no rule for .\(name)")
            #expect(page.contains("--\(name):"), "no colour for --\(name)")
        }
        // `.plain` is deliberately unnamed: an unclaimed run is already the page's own colour.
        #expect(MarkdownDocument.tokenClass(for: .plain) == nil)
        #expect(!page.contains("tok-plain"))
    }

    /// Both palettes, in one stylesheet, because the page switches appearance **itself**: probed,
    /// `prefers-color-scheme` follows the web view's effective appearance and re-evaluates live. A
    /// media query whose two halves were the same colour would look right in whichever appearance
    /// the developer happened to be in — which is the failure this pins.
    @Test("the page carries a light palette and a dark one, and they differ")
    func bothPalettesArePresent() throws {
        let page = QuickViewMarkdownStyle.document(body: "<p>x</p>")
        #expect(page.contains("@media (prefers-color-scheme: dark)"))
        for property in ["--text", "--background", "--link", "--tok-keyword"] {
            let values = Self.values(of: property, in: page)
            #expect(values.count == 2, "\(property) should be declared once per appearance")
            #expect(values.first != values.last, "\(property) is the same in both appearances")
        }
    }

    /// The measurement that decided the fence's appearance, kept as an assertion because the way to
    /// lose it is one plausible line. M17 authored the syntax palette against `.textBackgroundColor`
    /// and it clears 4.5:1 there; the gentlest fill anybody would reach for composites to `#E6E6E6`
    /// in light and takes `typeOrTag` down to **3.68:1**. So the fence is delimited by a border and
    /// keeps the page's own background, while *inline* code — which carries no coloured spans — gets
    /// the fill.
    @Test("a code fence is bordered rather than filled")
    func fencesAreNotFilled() throws {
        let page = QuickViewMarkdownStyle.document(body: "<p>x</p>")
        let fence = try #require(Self.rule(for: "pre", in: page))
        #expect(!fence.contains("background"), "a fill costs the syntax palette its contrast")
        #expect(fence.contains("border"))
        let inlineCode = try #require(Self.rule(for: ":not(pre) > code", in: page))
        #expect(inlineCode.contains("background: var(--code-fill)"))
    }

    /// The page's own text has to be legible on the page's own background, in both appearances —
    /// the same claim `SyntaxThemeTests` makes about the token colours, extended to the two colours
    /// that came from AppKit rather than from M17's authored table.
    @Test("text and links clear 4.5:1 on the page background, in both appearances")
    func documentColoursAreLegible() throws {
        let page = QuickViewMarkdownStyle.document(body: "<p>x</p>")
        let backgrounds = Self.values(of: "--background", in: page)
        for property in ["--text", "--link"] {
            let values = Self.values(of: property, in: page)
            #expect(values.count == backgrounds.count)
            for (ink, paper) in zip(values, backgrounds) {
                let ratio = Self.contrast(ink, paper)
                #expect(ratio >= 4.5, "\(property) \(ink) on \(paper) scores \(ratio)")
            }
        }
    }

    @Test("the fragment is wrapped rather than replaced")
    func theBodyReachesThePage() {
        let page = QuickViewMarkdownStyle.document(body: "<h1 id=\"a\">Alpha</h1>")
        #expect(page.hasPrefix("<!doctype html>"))
        #expect(page.contains("<h1 id=\"a\">Alpha</h1>"))
        // No script of ours either: the page is inert by construction, which is what lets the
        // `(no JavaScript)` mark stay off a Markdown preview.
        #expect(!page.contains("<script"))
    }

    // MARK: - Helpers

    /// A real 1×1 PNG. Real bytes rather than a stub, because the inliner asks the file system what
    /// type it is and hands the page a MIME type derived from that.
    private static let pngBytes = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAD0lEQVR4nGP8z4AATAxQAAAaZQEBpQnyVAAAAABJRU5ErkJggg==
    """)!

    /// A different 1×1 PNG — the file a document must not be able to reach.
    private static let secretPNGBytes = Data(base64Encoded: """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAAEElEQVR4nGNk+M+AFzAOWwUAxUgD/c15in4AAAAASUVORK5CYII=
    """)!

    private static let everyTokenClass = Set(
        SyntaxToken.Kind.allCases.compactMap { MarkdownDocument.tokenClass(for: $0) }
    )

    /// Every `class="tok-…"` in a rendered fragment, read out of the **output** rather than from the
    /// enum — so this measures what reached a tag, which is the lesson Slice 1 recorded.
    private static func tokenClasses(in html: String) -> Set<String> {
        var found: Set<String> = []
        var rest = Substring(html)
        while let start = rest.range(of: "class=\"tok-") {
            let tail = rest[start.upperBound...]
            guard let end = tail.firstIndex(of: "\"") else { break }
            found.insert("tok-" + String(tail[..<end]))
            rest = tail[end...]
        }
        return found
    }

    /// The declared values of one custom property, in source order — one per appearance.
    private static func values(of property: String, in css: String) -> [String] {
        css.split(whereSeparator: \.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(property + ":") else { return nil }
            return trimmed
                .dropFirst(property.count + 1)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
        }
    }

    /// The body of the first rule whose selector is exactly `selector`.
    private static func rule(for selector: String, in css: String) -> String? {
        guard let start = css.range(of: "\n\(selector) {") else { return nil }
        let tail = css[start.upperBound...]
        guard let end = tail.firstIndex(of: "}") else { return nil }
        return String(tail[..<end])
    }

    private static func contrast(_ ink: String, _ paper: String) -> Double {
        let (front, back) = (luminance(ink), luminance(paper))
        return (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }

    /// Written out by hand rather than borrowed from the code under test: reusing the app's own
    /// parser would prove the two agree rather than that either is right (docs/NOTES.md ▸ Testing).
    private static func luminance(_ hex: String) -> Double {
        let digits = Array(hex.dropFirst())
        guard digits.count == 6 else { return 0 }
        func channel(_ pair: ArraySlice<Character>) -> Double {
            let value = Double(Int(String(pair), radix: 16) ?? 0) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(digits[0..<2])
            + 0.7152 * channel(digits[2..<4])
            + 0.0722 * channel(digits[4..<6])
    }

    /// A surface showing `url` as a rendered page. **Awaited**, not spun for: the render is a
    /// detached task whose continuation needs the main actor to suspend, and the content rules are
}
