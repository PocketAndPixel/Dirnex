import AppKit
import DirnexCore
import os

/// What color each kind of token is drawn in (PLAN.md §M17 ▸ Slice 3, §M39 ▸ Slice 10).
///
/// Pure presentation, so it lives in the app rather than in `DirnexCore` — the same division
/// `QuickViewRenderStyle` and `SyntaxBadge`'s neighbors draw, and the one `TextPreview`'s own doc
/// comment states: the core decides *what a span is*, the app decides what it looks like.
///
/// **The palettes are editors' own** (`SyntaxColorTheme`: VS Code's, the default, then Xcode's and
/// GitHub's), and the user picks one in Settings ▸ Panels.
///
/// **Every color is a light/dark pair, and both halves are authored.** M17 opened with "system
/// dynamic colors, because each resolves per appearance for free" — which is right in dark mode
/// and wrong in light, measured before a line of this file was written (2026-08-06, both
/// appearances, against `.textBackgroundColor` with alpha composited):
///
/// | | light, on `#FFFFFF` | dark, on `#1E1E1E` |
/// |---|---|---|
/// | `.systemGreen` | **2.22:1** | 8.25:1 |
/// | `.systemTeal` | **2.16:1** | 8.97:1 |
/// | `.systemOrange` / `.systemYellow` | 2.31 / **1.51** | 7.47 / 11.81 |
/// | `.systemRed` / `.systemBlue` / `.systemPurple` | 3.57 / 3.52 / 4.17 | 4.86 / 5.16 / 4.59 |
///
/// The system palette is tuned for **fills** — a button, a badge, a selection — not for text on a
/// white background, and the hues that fail are exactly the ones a syntax theme wants most. So no
/// `.system*` color appears here in either appearance, and `SyntaxThemeTests` holds every theme's
/// every value to 4.5:1 in both appearances rather than trusting a screenshot of one.
///
/// ## One color per kind, whatever the theme
///
/// `keyword`, `string` and the rest are each **one** `NSColor` that resolves, at draw time, to the
/// selected theme's value for the appearance it is drawn in. Every surface — the source view, the
/// JSON tree, a CSV's columns, the compare and merge windows — holds these objects in its text, so a
/// change of theme needs no rebuilt document anywhere, only a redraw (`SyntaxThemeRepaint`), the way
/// a light/dark flip needs nothing at all. Probed 2026-11-14: a dynamic color asks its provider again
/// on every resolution, `cgColor` included, and keeps no answer from the last one.
enum SyntaxTheme {
    /// The theme every following color resolves through. `AppPreferences.shared` sets it, at launch
    /// and on each change; nothing else should, since a second writer would recolor the screen behind
    /// the preference's back.
    ///
    /// Behind a lock rather than on the main actor because a color is resolved wherever it is drawn
    /// or converted, which is not always the main thread.
    static var current: SyntaxColorTheme { selection.withLock { $0 } }

    static func select(_ theme: SyntaxColorTheme) {
        selection.withLock { $0 = theme }
    }

    private static let selection = OSAllocatedUnfairLock(initialState: SyntaxColorTheme.standard)

    /// The color for `kind`, following the selected theme, or `nil` for text the scanner made no
    /// claim about.
    ///
    /// `nil` rather than `.textColor` on purpose: highlighting *adds* foreground color to a
    /// document that already renders correctly, so a run with no color is a run left exactly as it
    /// was — which is what makes an unknown file type not a special case.
    static func color(for kind: SyntaxToken.Kind) -> NSColor? {
        switch kind {
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .typeOrTag: typeOrTag
        case .inserted: inserted
        case .deleted: deleted
        case .plain: nil
        }
    }

    /// The color for `kind` in `theme` whichever theme is selected — what the Settings sample, a
    /// page's stylesheet and the contrast tests ask for. Still a light/dark pair.
    static func color(for kind: SyntaxToken.Kind, in theme: SyntaxColorTheme) -> NSColor? {
        fixed[theme]?[kind]
    }

    static let keyword = following(.keyword)
    static let string = following(.string)
    static let comment = following(.comment)
    static let number = following(.number)
    static let typeOrTag = following(.typeOrTag)
    /// Its own entry rather than borrowing another kind's color; see `SyntaxToken.Kind.inserted`.
    /// A theme may still give it the same value as a code kind, as VS Code gives it the number's.
    static let inserted = following(.inserted)
    static let deleted = following(.deleted)

    /// A color for `kind` that resolves through whatever `theme` answers at draw time.
    ///
    /// `theme` is a parameter so a test can follow a value of its own rather than the one the whole
    /// app draws with.
    static func following(
        _ kind: SyntaxToken.Kind,
        theme: @escaping @Sendable () -> SyntaxColorTheme = { SyntaxTheme.current }
    ) -> NSColor {
        NSColor(name: NSColor.Name("dirnex.syntax.\(kind.rawValue)")) { appearance in
            let pair = theme().pair(for: kind) ?? SyntaxColorPair(light: 0, dark: 0xFF_FFFF)
            return sRGB(isDark(appearance) ? pair.dark : pair.light)
        }
    }

    /// Every theme's colors, each a pair fixed to that theme, built once.
    private static let fixed: [SyntaxColorTheme: [SyntaxToken.Kind: NSColor]] = {
        var table: [SyntaxColorTheme: [SyntaxToken.Kind: NSColor]] = [:]
        for theme in SyntaxColorTheme.allCases {
            var colors: [SyntaxToken.Kind: NSColor] = [:]
            for kind in SyntaxToken.Kind.allCases {
                guard let pair = theme.pair(for: kind) else { continue }
                let name = NSColor.Name("dirnex.syntax.\(theme.rawValue).\(kind.rawValue)")
                colors[kind] = NSColor(name: name) { appearance in
                    sRGB(isDark(appearance) ? pair.dark : pair.light)
                }
            }
            table[theme] = colors
        }
        return table
    }()

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// An authored value, always in **sRGB** — a raw `NSColor(red:green:blue:)` is in the generic
    /// calibrated space, where the same numbers are a visibly different color.
    private static func sRGB(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
