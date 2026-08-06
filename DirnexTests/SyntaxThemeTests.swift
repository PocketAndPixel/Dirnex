import AppKit
import DirnexCore
import Testing

@testable import Dirnex

/// The colour half of M17 (PLAN.md §M17 ▸ Slice 3), and the reason the theme is a table of
/// light/dark pairs rather than the system palette the milestone opened with.
///
/// The contrast tests here are the point of the whole file. Only one appearance is ever on screen,
/// so "legible in dark mode too" is a claim no screenshot can check — and the measurement that
/// prompted the redesign found `.systemGreen` at **2.22:1** on a white text background while it
/// scores 8.25:1 on a dark one. A luminance test over an sRGB value resolves identically under
/// `.aqua` and `.darkAqua`, which is exactly what makes it pinnable (docs/NOTES.md ▸ the M15
/// palette, where the same reasoning produced the derived-foreground rule).
@Suite("Syntax theme")
@MainActor
struct SyntaxThemeTests {
    /// The floor. WCAG AA for body text, and every authored value clears it with room — the
    /// narrowest is `typeOrTag` in light mode at 4.52:1.
    private static let floor = 4.5

    // MARK: - The colour table

    @Test("every kind the scanner emits has a colour, and .plain has none")
    func everyEmittedKindIsColoured() {
        for kind in SyntaxToken.Kind.allCases where kind != .plain {
            #expect(SyntaxTheme.color(for: kind) != nil, "\(kind) has no colour")
        }
        // Never emitted, and deliberately absent rather than mapped to `.textColor`: a run with no
        // colour is a run left exactly as the text view already drew it.
        #expect(SyntaxTheme.color(for: .plain) == nil)
    }

    @Test("every colour clears 4.5:1 on the text background, in both appearances")
    func contrastHoldsInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for kind in SyntaxToken.Kind.allCases {
                guard let colour = SyntaxTheme.color(for: kind) else { continue }
                let ratio = Self.contrast(colour, onTextBackgroundIn: appearance)
                #expect(
                    ratio >= Self.floor,
                    "\(kind) scores \(ratio) in \(name.rawValue), below \(Self.floor)"
                )
            }
        }
    }

    @Test("the dark half really is a different colour from the light half")
    func thePairIsAPair() throws {
        // A `dynamicProvider` that ignored its argument would still pass the contrast test in one
        // appearance and fail silently in the other, so this pins that the switch happens at all.
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        for kind in SyntaxToken.Kind.allCases {
            guard let colour = SyntaxTheme.color(for: kind) else { continue }
            #expect(
                Self.resolved(colour, in: light) != Self.resolved(colour, in: dark),
                "\(kind) resolves identically in both appearances"
            )
        }
    }

    @Test("no two kinds resolve to the same colour, except the pair that means to")
    func kindsAreTellableApart() throws {
        // A reader has to see keyword and string as different things. `deleted` and `string` share
        // a red on purpose — a diff has no strings and code has no diff lines, so they never meet.
        let appearance = try #require(NSAppearance(named: .aqua))
        var seen: [String: SyntaxToken.Kind] = [:]
        var clashes: [String] = []
        for kind in SyntaxToken.Kind.allCases {
            guard let colour = SyntaxTheme.color(for: kind) else { continue }
            let key = Self.resolved(colour, in: appearance)
            if let other = seen[key], !Self.mayShareAColour(kind, other) {
                clashes.append("\(kind) == \(other)")
            }
            seen[key] = kind
        }
        #expect(clashes.isEmpty)
    }

    // MARK: - End to end

    @Test("a previewed Swift file arrives with coloured runs in its text storage")
    func highlightingReachesTheScreen() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("Sample.swift", contents: """
        // a comment
        import Foundation
        let name: String = "hi"
        """)
        let textView = try await Self.previewedTextView(url)
        let colours = Self.foregroundColours(in: textView)

        #expect(colours.contains(SyntaxTheme.comment))
        #expect(colours.contains(SyntaxTheme.keyword))
        #expect(colours.contains(SyntaxTheme.string))
        #expect(colours.contains(SyntaxTheme.typeOrTag))
        // The document is unchanged — highlighting only ever adds colour.
        #expect(textView.string.hasPrefix("// a comment\nimport Foundation"))
    }

    @Test("a file no grammar claims renders in one colour, exactly as it did before M17")
    func unknownExtensionsAreNotASpecialCase() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "class if let \"quoted\" 42\n")
        let textView = try await Self.previewedTextView(url)

        #expect(Self.foregroundColours(in: textView) == [NSColor.textColor])
    }

    @Test("an out-of-range token is dropped rather than raising inside a preview")
    func mismatchedTokensDoNotCrash() {
        // The core promises in-range offsets and its tests pin that — but `addAttribute` with a bad
        // `NSRange` *raises*, and a preview is the wrong place to find out. The guard has to fail as
        // a missing colour.
        let surface = QuickViewTextView()
        surface.show(
            TextPreview(text: "abc", isTruncated: false),
            tokens: [
                SyntaxToken(offset: 0, length: 1, kind: .keyword),
                SyntaxToken(offset: 2, length: 99, kind: .string)
            ]
        )
        let textView = Self.documentTextView(of: surface)
        #expect(textView?.string == "abc")
        #expect(Self.foregroundColours(in: textView).contains(SyntaxTheme.keyword))
        #expect(!Self.foregroundColours(in: textView).contains(SyntaxTheme.string))
    }

    @Test("TextKit 2's lazy layout survives an attributed document")
    func lazyLayoutSurvives() async throws {
        // The measurement that made the whole design affordable, kept as an assertion because the
        // way to lose it is a one-line edit somewhere else: reading `.layoutManager` drops the view
        // to TextKit 1, where laying out a large document takes seconds (docs/NOTES.md).
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("Sample.swift", contents: "let x = 1\n")
        let textView = try await Self.previewedTextView(url)
        #expect(textView.textLayoutManager != nil)
    }

    // MARK: - Helpers

    /// Whether two kinds are allowed to share a colour: only the diff pair, which cannot appear in
    /// the same document as the code kinds it borrows a hue from.
    private static func mayShareAColour(_ one: SyntaxToken.Kind, _ other: SyntaxToken.Kind) -> Bool {
        let pair: Set<SyntaxToken.Kind> = [one, other]
        return pair == [.deleted, .string] || pair == [.inserted, .comment]
    }

    /// The text view of a loaded preview, **awaited** rather than spun for.
    ///
    /// `QuickViewTextPreviewTests.loaded` pumps the run loop, which is enough to lay the surface out
    /// — every test that only hit-tests it passes on that alone. It is not enough to land the
    /// document: the read is a detached task whose continuation needs the main actor to *suspend*,
    /// which a `RunLoop.run(until:)` does not do. So the content assertions here await instead, and
    /// the empty string that a spin-only wait produces is why they are the tests that found it.
    private static func previewedTextView(_ url: URL) async throws -> NSTextView {
        let preview = try QuickViewTextPreviewTests.loaded(url)
        let hit = try #require(preview.hitTest(NSPoint(x: 200, y: 200)))
        let textView = try #require(QuickViewTextPreviewTests.enclosingTextView(of: hit))
        for _ in 0..<200 {
            if !textView.string.isEmpty { return textView }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return textView
    }

    private static func documentTextView(of surface: QuickViewTextView) -> NSTextView? {
        (surface.interactiveSubtree as? NSScrollView)?.documentView as? NSTextView
    }

    /// Every distinct `.foregroundColor` in the document, as the colour objects themselves — the
    /// theme's own `NSColor`s, so a comparison against `SyntaxTheme.comment` is exact.
    private static func foregroundColours(in textView: NSTextView?) -> Set<NSColor> {
        guard let storage = textView?.textStorage else { return [] }
        var found: Set<NSColor> = []
        storage.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let colour = value as? NSColor { found.insert(colour) }
        }
        return found
    }

    /// `colour` composited on `.textBackgroundColor`, against that same background.
    private static func contrast(_ colour: NSColor, onTextBackgroundIn appearance: NSAppearance)
        -> Double {
        var top = colour
        var under = NSColor.textBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            top = colour.usingColorSpace(.sRGB) ?? colour
            under = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
        }
        let flat = flattened(top, on: under)
        let (ink, paper) = (luminance(flat), luminance(under))
        return (max(ink, paper) + 0.05) / (min(ink, paper) + 0.05)
    }

    private static func resolved(_ colour: NSColor, in appearance: NSAppearance) -> String {
        var srgb = colour
        appearance.performAsCurrentDrawingAppearance {
            srgb = colour.usingColorSpace(.sRGB) ?? colour
        }
        return String(
            format: "%.4f,%.4f,%.4f",
            srgb.redComponent, srgb.greenComponent, srgb.blueComponent
        )
    }

    /// A semantic colour can carry alpha (`.secondaryLabelColor` is black at 50 %), so it has to be
    /// measured as it is seen rather than as its opaque value.
    private static func flattened(_ top: NSColor, on under: NSColor) -> NSColor {
        let alpha = top.alphaComponent
        return NSColor(
            srgbRed: top.redComponent * alpha + under.redComponent * (1 - alpha),
            green: top.greenComponent * alpha + under.greenComponent * (1 - alpha),
            blue: top.blueComponent * alpha + under.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private static func luminance(_ colour: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let raw = Double(value)
            return raw <= 0.03928 ? raw / 12.92 : pow((raw + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(colour.redComponent)
            + 0.7152 * channel(colour.greenComponent)
            + 0.0722 * channel(colour.blueComponent)
    }
}
