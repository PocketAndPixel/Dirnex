import AppKit
import DirnexCore

/// What colour each kind of token is drawn in (PLAN.md §M17 ▸ Slice 3).
///
/// Pure presentation, so it lives in the app rather than in `DirnexCore` — the same division
/// `QuickViewRenderStyle` and `SyntaxBadge`'s neighbours draw, and the one `TextPreview`'s own doc
/// comment states: the core decides *what a span is*, the app decides what it looks like.
///
/// **The palette is VS Code's, Dark Modern and Light Modern** — the `dark_plus` / `light_plus`
/// token colours those two themes inherit. That is a deliberate choice of *whose* theme rather
/// than an invented one: a file manager's preview is read next to the editor the file will be
/// opened in, and matching the editor is worth more than any hue picked in isolation.
///
/// **Every colour is a light/dark pair, and both halves are authored.** M17 opened with "system
/// dynamic colours, because each resolves per appearance for free" — which is right in dark mode
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
/// `.system*` colour appears here in either appearance.
///
/// Both halves were then re-measured as published, and **neither needed adjusting**: the narrowest
/// is `typeOrTag` at 4.59:1 in light, and every dark value clears 5:1. That is not luck —
/// `.textBackgroundColor` resolves to exactly `#1E1E1E` in dark mode, which *is* VS Code's classic
/// editor background, so the dark half is measured on the background it was designed for. The goal
/// the plan stated is untouched: one `NSColor` per kind that resolves itself per appearance, with
/// no Settings surface, no persistence and no picker — and `SyntaxThemeTests` pins the ratio in
/// both appearances rather than trusting a screenshot of one.
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

    /// `#0000FF` / `#569CD6` — 8.59:1 light, 5.65:1 dark.
    static let keyword = pair("keyword", light: 0x00_00FF, dark: 0x56_9CD6)
    /// `#A31515` / `#CE9178` — 7.85:1 light, 6.31:1 dark. The dark half is the whole reason this
    /// palette was worth swapping to: a literal drawn in salmon reads as a literal, where the red
    /// it replaces read as an error.
    static let string = pair("string", light: 0xA3_1515, dark: 0xCE_9178)
    /// `#008000` / `#6A9955` — 5.14:1 light, 5.00:1 dark.
    static let comment = pair("comment", light: 0x00_8000, dark: 0x6A_9955)
    /// `#098658` / `#B5CEA8` — 4.60:1 light, 9.81:1 dark.
    static let number = pair("number", light: 0x09_8658, dark: 0xB5_CEA8)
    /// `#267F99` / `#4EC9B0` — 4.59:1 light, 8.18:1 dark. The narrowest margin in the table, and
    /// kept as published: a type name that reads as a *different* teal from the one the editor
    /// beside it draws would be a worse answer than one that clears the bar by 0.09.
    static let typeOrTag = pair("typeOrTag", light: 0x26_7F99, dark: 0x4E_C9B0)
    /// `#098658` / `#B5CEA8` — 4.60:1 light, 9.81:1 dark. Deliberately its own entry rather than
    /// borrowing another kind's green; see `SyntaxToken.Kind.inserted`. VS Code's own table gives
    /// it the same value as `number`, which is why `SyntaxThemeTests` allows that one clash.
    static let inserted = pair("inserted", light: 0x09_8658, dark: 0xB5_CEA8)
    /// `#A31515` / `#CE9178` — 7.85:1 light, 6.31:1 dark.
    static let deleted = pair("deleted", light: 0xA3_1515, dark: 0xCE_9178)

    /// One dynamic colour from an authored light value and an authored dark one.
    ///
    /// A single `NSColor` rather than two, so the *caller* never asks which appearance it is in —
    /// which is what lets the same attributed string keep rendering correctly when the user flips
    /// the system between light and dark with the preview already on screen. AppKit resolves it at
    /// draw time.
    private static func pair(_ name: String, light: Int, dark: Int) -> NSColor {
        NSColor(name: NSColor.Name("dirnex.syntax.\(name)")) { appearance in
            sRGB(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light)
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
