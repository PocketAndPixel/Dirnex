import AppKit
import DirnexCore

/// What colour each kind of token is drawn in (PLAN.md §M17 ▸ Slice 3).
///
/// Pure presentation, so it lives in the app rather than in `DirnexCore` — the same division
/// `QuickViewRenderStyle` and `SyntaxBadge`'s neighbours draw, and the one `TextPreview`'s own doc
/// comment states: the core decides *what a span is*, the app decides what it looks like.
///
/// **Every colour is a light/dark pair, and that is a correction to the plan.** M17 opened with
/// "system dynamic colours, because each resolves per appearance for free" — which is right in dark
/// mode and wrong in light, measured before a line of this file was written (2026-08-06, both
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
/// white background, and the hues that fail are exactly the ones a syntax theme wants most. So the
/// light half is authored to clear **4.5:1**, and the dark half stays the system colour, where every
/// one of them already measures AA. The goal the plan actually stated is untouched: one `NSColor`
/// per kind that resolves itself per appearance, with no Settings surface, no persistence and no
/// picker — and the claim is now *stronger* than the plan could make, because
/// `SyntaxThemeTests` pins the ratio in both appearances rather than trusting a screenshot of one.
enum SyntaxTheme {
    /// The colour for `kind`, or `nil` for text the scanner made no claim about.
    ///
    /// `nil` rather than `.textColor` on purpose: highlighting *adds* foreground colour to a
    /// document that already renders correctly, so a run with no colour is a run left exactly as it
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

    // The light values are Xcode's own "Default (Light)" theme, which is what a Mac developer is
    // comparing this against, and each was measured on white rather than taken on trust.

    /// `#9B2393` — 6.87:1 light, 4.59:1 dark.
    static let keyword = pair("keyword", light: 0x9B_2393, dark: .systemPurple)
    /// `#C41A16` — 5.99:1 light, 4.86:1 dark.
    static let string = pair("string", light: 0xC4_1A16, dark: .systemRed)
    /// `#267507` — 5.79:1 light, 8.25:1 dark.
    static let comment = pair("comment", light: 0x26_7507, dark: .systemGreen)
    /// `#1C00CF` — 10.77:1 light, 5.16:1 dark.
    static let number = pair("number", light: 0x1C_00CF, dark: .systemBlue)
    /// `#3E8087` — 4.52:1 light, 8.97:1 dark. The narrowest margin in the table, and kept because
    /// it is Xcode's own: a type name that reads as a *different* teal from the one every Mac
    /// developer knows would be a worse answer than one that clears the bar by 0.02.
    static let typeOrTag = pair("typeOrTag", light: 0x3E_8087, dark: .systemTeal)
    /// `#1A7F37` — 5.08:1 light, 8.25:1 dark. Deliberately its own entry rather than borrowing
    /// `comment`'s green; see `SyntaxToken.Kind.inserted`.
    static let inserted = pair("inserted", light: 0x1A_7F37, dark: .systemGreen)
    /// `#C41A16` — 5.99:1 light, 4.86:1 dark.
    static let deleted = pair("deleted", light: 0xC4_1A16, dark: .systemRed)

    /// One dynamic colour from an authored light value and a system dark one.
    ///
    /// A single `NSColor` rather than two, so the *caller* never asks which appearance it is in —
    /// which is what lets the same attributed string keep rendering correctly when the user flips
    /// the system between light and dark with the preview already on screen. AppKit resolves it at
    /// draw time.
    private static func pair(_ name: String, light: Int, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("dirnex.syntax.\(name)")) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : sRGB(light)
        }
    }

    /// An authored value, always in **sRGB** — a raw `NSColor(red:green:blue:)` is in the generic
    /// calibrated space, where the same numbers are a visibly different colour.
    private static func sRGB(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
