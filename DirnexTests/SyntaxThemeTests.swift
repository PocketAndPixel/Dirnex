import AppKit
import DirnexCore
import os
import Testing

@testable import Dirnex

/// The color half of M17 (PLAN.md §M17 ▸ Slice 3), and the reason each theme is a table of
/// light/dark pairs rather than the system palette the milestone opened with; since M39 ▸ Slice 10,
/// three such tables, every one held to the same floor.
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
    /// The floor. WCAG AA for body text, held by every theme in both appearances. The narrowest is
    /// VS Code's light `typeOrTag` at 4.59:1, then Xcode's dark comment, lightened to 4.66:1 for it.
    private static let floor = 4.5

    /// The kinds a source file colors. The diff pair is apart: a theme may give an added line a code
    /// kind's value, as VS Code gives it the number's.
    private static let codeKinds: [SyntaxToken.Kind] = [
        .keyword,
        .string,
        .comment,
        .number,
        .typeOrTag
    ]

    // MARK: - The color table

    @Test("every theme colors every kind the scanner emits, and .plain in none")
    func everyEmittedKindIsColored() {
        for kind in SyntaxToken.Kind.allCases where kind != .plain {
            #expect(SyntaxTheme.color(for: kind) != nil, "\(kind) has no color")
            for theme in SyntaxColorTheme.allCases {
                #expect(SyntaxTheme.color(for: kind, in: theme) != nil, "\(theme) has no \(kind)")
            }
        }
        // Never emitted, and deliberately absent rather than mapped to `.textColor`: a run with no
        // color is a run left exactly as the text view already drew it.
        #expect(SyntaxTheme.color(for: .plain) == nil)
        for theme in SyntaxColorTheme.allCases {
            #expect(SyntaxTheme.color(for: .plain, in: theme) == nil)
        }
    }

    @Test("every theme's every color clears 4.5:1 on the text background, in both appearances")
    func contrastHoldsInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for theme in SyntaxColorTheme.allCases {
                for kind in SyntaxToken.Kind.allCases {
                    guard let color = SyntaxTheme.color(for: kind, in: theme) else { continue }
                    let ratio = Self.contrast(color, onTextBackgroundIn: appearance)
                    #expect(
                        ratio >= Self.floor,
                        "\(theme) \(kind) scores \(ratio) in \(name.rawValue), below \(Self.floor)"
                    )
                }
            }
        }
    }

    @Test("the dark half really is a different color from the light half, in every theme")
    func thePairIsAPair() throws {
        // A `dynamicProvider` that ignored its argument would still pass the contrast test in one
        // appearance and fail silently in the other, so this pins that the switch happens at all.
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        for theme in SyntaxColorTheme.allCases {
            for kind in SyntaxToken.Kind.allCases {
                guard let color = SyntaxTheme.color(for: kind, in: theme) else { continue }
                #expect(
                    Self.hex(color, in: light) != Self.hex(color, in: dark),
                    "\(theme) \(kind) resolves identically in both appearances"
                )
            }
        }
    }

    @Test("no two code kinds share a color, nor the two diff kinds, in any theme or appearance")
    func kindsAreTellableApart() throws {
        // A reader has to see keyword and string as different things. A diff kind may take a code
        // kind's value, as VS Code's and Xcode's own tables do: no source file puts the two side by
        // side, and inside a ```diff fence a `+` line is told from a list marker by its position.
        // GitHub's light tag color is the constant's blue, which is why its `typeOrTag` is `entity`.
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for theme in SyntaxColorTheme.allCases {
                let code = try Self.codeKinds.map {
                    try Self.hex(#require(SyntaxTheme.color(for: $0, in: theme)), in: appearance)
                }
                #expect(
                    Set(code).count == code.count,
                    "\(theme) repeats a code color in \(name.rawValue)"
                )
                let inserted = try #require(SyntaxTheme.color(for: .inserted, in: theme))
                let deleted = try #require(SyntaxTheme.color(for: .deleted, in: theme))
                #expect(Self.hex(inserted, in: appearance) != Self.hex(deleted, in: appearance))
            }
        }
    }

    /// The default is the table M17 shipped, value for value, so an install that never opens Settings
    /// draws exactly as it did before there was a choice.
    @Test("VS Code, the default, is M17's palette unchanged")
    func theDefaultIsUnchanged() throws {
        #expect(SyntaxColorTheme.standard == .vsCode)
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let shipped: [SyntaxToken.Kind: (String, String)] = [
            .keyword: ("#0000FF", "#569CD6"),
            .string: ("#A31515", "#CE9178"),
            .comment: ("#008000", "#6A9955"),
            .number: ("#098658", "#B5CEA8"),
            .typeOrTag: ("#267F99", "#4EC9B0"),
            .inserted: ("#098658", "#B5CEA8"),
            .deleted: ("#A31515", "#CE9178")
        ]
        for (kind, (lightHex, darkHex)) in shipped {
            let color = try #require(SyntaxTheme.color(for: kind, in: .vsCode))
            #expect(Self.hex(color, in: light) == lightHex, "\(kind)")
            #expect(Self.hex(color, in: dark) == darkHex, "\(kind)")
        }
    }

    /// The mechanism a change of theme rests on: the color a document holds is the same object
    /// before and after, and answers with the new theme's value the next time it is drawn.
    @Test("a following color resolves through whichever theme its source answers, at each draw")
    func followingColorsFollow() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        let source = OSAllocatedUnfairLock(initialState: SyntaxColorTheme.vsCode)
        let keyword = SyntaxTheme.following(.keyword) { source.withLock { $0 } }

        #expect(Self.hex(keyword, in: light) == "#0000FF")
        source.withLock { $0 = .xcode }
        #expect(Self.hex(keyword, in: light) == "#9B2393")
        #expect(Self.hex(keyword, in: dark) == "#FC5FA3")
        source.withLock { $0 = .gitHub }
        #expect(Self.hex(keyword, in: light) == "#CF222E")
    }

    // MARK: - End to end

    @Test("a previewed Swift file arrives with colored runs in its text storage")
    func highlightingReachesTheScreen() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("Sample.swift", contents: """
        // a comment
        import Foundation
        let name: String = "hi"
        """)
        let textView = try await Self.previewedTextView(url)
        let colors = Self.foregroundColors(in: textView)

        #expect(colors.contains(SyntaxTheme.comment))
        #expect(colors.contains(SyntaxTheme.keyword))
        #expect(colors.contains(SyntaxTheme.string))
        #expect(colors.contains(SyntaxTheme.typeOrTag))
        // The document is unchanged — highlighting only ever adds color.
        #expect(textView.string.hasPrefix("// a comment\nimport Foundation"))
    }

    @Test("a file no grammar claims renders in one color, exactly as it did before M17")
    func unknownExtensionsAreNotASpecialCase() async throws {
        let tree = try TempDirectory()
        defer { tree.cleanup() }
        let url = try tree.write("notes.txt", contents: "class if let \"quoted\" 42\n")
        let textView = try await Self.previewedTextView(url)

        #expect(Self.foregroundColors(in: textView) == [NSColor.textColor])
    }

    @Test("an out-of-range token is dropped rather than raising inside a preview")
    func mismatchedTokensDoNotCrash() {
        // The core promises in-range offsets and its tests pin that — but `addAttribute` with a bad
        // `NSRange` *raises*, and a preview is the wrong place to find out. The guard has to fail as
        // a missing color.
        let surface = QuickViewTextView(findOptions: .scratch())
        surface.show(
            TextPreview(text: "abc", isTruncated: false),
            tokens: [
                SyntaxToken(offset: 0, length: 1, kind: .keyword),
                SyntaxToken(offset: 2, length: 99, kind: .string)
            ]
        )
        let textView = Self.documentTextView(of: surface)
        #expect(textView?.string == "abc")
        #expect(Self.foregroundColors(in: textView).contains(SyntaxTheme.keyword))
        #expect(!Self.foregroundColors(in: textView).contains(SyntaxTheme.string))
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

    /// The text view of a loaded preview, **awaited** rather than spun for.
    ///
    /// `QuickViewTextPreviewTests.loaded` waits for the *surface* — enough for every test that only
    /// hit-tests it, and not enough to land the *document*: the read is a detached task whose
    /// continuation arrives on its own schedule. So the content assertions here poll for the text
    /// itself. (That helper used to spin the run loop, which cannot land a continuation at all —
    /// the empty string it produced is why these were the tests that found it.)
    private static func previewedTextView(_ url: URL) async throws -> NSTextView {
        let preview = try await QuickViewTextPreviewTests.loaded(url)
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

    /// Every distinct `.foregroundColor` in the document, as the color objects themselves — the
    /// theme's own `NSColor`s, so a comparison against `SyntaxTheme.comment` is exact.
    private static func foregroundColors(in textView: NSTextView?) -> Set<NSColor> {
        guard let storage = textView?.textStorage else { return [] }
        var found: Set<NSColor> = []
        storage.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: storage.length)
        ) { value, _, _ in
            if let color = value as? NSColor { found.insert(color) }
        }
        return found
    }

    /// `color` composited on `.textBackgroundColor`, against that same background.
    private static func contrast(_ color: NSColor, onTextBackgroundIn appearance: NSAppearance)
        -> Double {
        var top = color
        var under = NSColor.textBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            top = color.usingColorSpace(.sRGB) ?? color
            under = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
        }
        let flat = flattened(top, on: under)
        let (ink, paper) = (luminance(flat), luminance(under))
        return (max(ink, paper) + 0.05) / (min(ink, paper) + 0.05)
    }

    /// `color` as it resolves in `appearance`, as `#RRGGBB` in sRGB.
    static func hex(_ color: NSColor, in appearance: NSAppearance) -> String {
        var srgb = color
        appearance.performAsCurrentDrawingAppearance {
            srgb = color.usingColorSpace(.sRGB) ?? color
        }
        return String(
            format: "#%02X%02X%02X",
            Int((srgb.redComponent * 255).rounded()),
            Int((srgb.greenComponent * 255).rounded()),
            Int((srgb.blueComponent * 255).rounded())
        )
    }

    /// A semantic color can carry alpha (`.secondaryLabelColor` is black at 50 %), so it has to be
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

    private static func luminance(_ color: NSColor) -> Double {
        func channel(_ value: CGFloat) -> Double {
            let raw = Double(value)
            return raw <= 0.03928 ? raw / 12.92 : pow((raw + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
