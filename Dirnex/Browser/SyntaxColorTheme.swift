import DirnexCore

/// One authored color for each appearance, as `0xRRGGBB` in sRGB.
struct SyntaxColorPair: Equatable, Sendable {
    let light: Int
    let dark: Int
}

/// The syntax themes the user can pick in Settings ▸ Panels (PLAN.md §M39 ▸ Slice 10).
///
/// **Three editors' own palettes, read from their own files**, for M17's reason: a preview is read
/// beside the editor the file will be opened in, and matching that editor beats any hue picked in
/// isolation. VS Code's is the default and is the table M17 shipped, value for value, so an untouched
/// install draws exactly as before.
///
/// **Only the token colors change.** Each theme is drawn on the system's text background (`#FFFFFF`
/// light, `#1E1E1E` dark) rather than on its own, so a pane's preview stays one surface with the rest
/// of the window, and every value is held to 4.5:1 *there* (`SyntaxThemeTests`). Measured 2026-11-14,
/// two values needed a decision:
///
/// - **Xcode's dark comment `#6C7986` scores 3.74:1** on `#1E1E1E` (3.7 on Xcode's own `#1F1F24`
///   too). It is lightened along its own hue to `#7C8996`, 4.66:1, the first step that clears the bar
///   with a little room.
/// - **GitHub's light palette gives a tag the constant's blue** (`entity-tag` and `constant` are both
///   `#0550AE`), so a JSON key and the number beside it would read as one thing. `typeOrTag` takes
///   GitHub's `entity` instead, its color for a type or a function's name.
enum SyntaxColorTheme: String, CaseIterable, Identifiable, Sendable {
    case vsCode = "vscode"
    case xcode
    case gitHub = "github"

    /// The shipped default, which is the palette every surface drew before there was a choice.
    static let standard = SyntaxColorTheme.vsCode

    var id: String { rawValue }

    /// The editor's own name, which no language translates.
    var title: String {
        switch self {
        case .vsCode: "VS Code"
        case .xcode: "Xcode"
        case .gitHub: "GitHub"
        }
    }

    /// The pair for `kind`, or `nil` for `.plain`, which keeps the text view's own color.
    func pair(for kind: SyntaxToken.Kind) -> SyntaxColorPair? {
        switch self {
        case .vsCode: Self.vsCodePair(for: kind)
        case .xcode: Self.xcodePair(for: kind)
        case .gitHub: Self.gitHubPair(for: kind)
        }
    }

    // MARK: - The palettes

    /// VS Code's Light Modern and Dark Modern, the `light_plus` / `dark_plus` token colors both
    /// inherit (M17). Light 4.59–8.59:1, dark 5.00–9.81:1. A diff borrows two of its own values:
    /// `deleted` is the string's red and `inserted` the number's green, as VS Code draws them.
    private static func vsCodePair(for kind: SyntaxToken.Kind) -> SyntaxColorPair? {
        switch kind {
        case .keyword: SyntaxColorPair(light: 0x00_00FF, dark: 0x56_9CD6)
        case .string, .deleted: SyntaxColorPair(light: 0xA3_1515, dark: 0xCE_9178)
        case .comment: SyntaxColorPair(light: 0x00_8000, dark: 0x6A_9955)
        case .number, .inserted: SyntaxColorPair(light: 0x09_8658, dark: 0xB5_CEA8)
        case .typeOrTag: SyntaxColorPair(light: 0x26_7F99, dark: 0x4E_C9B0)
        case .plain: nil
        }
    }

    /// Xcode's Default (Light) and Default (Dark), read from the `.xccolortheme` files inside
    /// Xcode.app (`DVTUserInterfaceKit.framework/…/FontAndColorThemes`). `typeOrTag` is "Other Type
    /// Names" (`identifier.type.system`), Xcode's color for `String` and `Int`. Xcode colors no diff,
    /// so a removed line takes its string red and an added one the teal it gives a project's own
    /// functions (`identifier.function`), the nearest it has to green. Light 5.40–12.49:1, dark
    /// 4.66–9.00:1, the floor being the lightened comment above.
    private static func xcodePair(for kind: SyntaxToken.Kind) -> SyntaxColorPair? {
        switch kind {
        case .keyword: SyntaxColorPair(light: 0x9B_2393, dark: 0xFC_5FA3)
        case .string, .deleted: SyntaxColorPair(light: 0xC4_1A16, dark: 0xFC_6A5D)
        case .comment: SyntaxColorPair(light: 0x5D_6C79, dark: 0x7C_8996)
        case .number: SyntaxColorPair(light: 0x1C_00CF, dark: 0xD0_BF69)
        case .typeOrTag: SyntaxColorPair(light: 0x39_00A0, dark: 0xD0_A8FF)
        case .inserted: SyntaxColorPair(light: 0x32_6D74, dark: 0x67_B7A4)
        case .plain: nil
        }
    }

    /// GitHub's, the `--color-prettylights-syntax-*` values its own Markdown stylesheet carries for
    /// light and dark: `keyword`, `string`, `comment`, `constant` for a number, `entity` for a type
    /// (see above), and the `markup-inserted-text` and `markup-deleted-text` a diff is drawn in.
    /// Light 5.36–12.81:1, dark 5.72–13.13:1.
    private static func gitHubPair(for kind: SyntaxToken.Kind) -> SyntaxColorPair? {
        switch kind {
        case .keyword: SyntaxColorPair(light: 0xCF_222E, dark: 0xFF_7B72)
        case .string: SyntaxColorPair(light: 0x0A_3069, dark: 0xA5_D6FF)
        case .comment: SyntaxColorPair(light: 0x59_636E, dark: 0x91_98A1)
        case .number: SyntaxColorPair(light: 0x05_50AE, dark: 0x79_C0FF)
        case .typeOrTag: SyntaxColorPair(light: 0x66_39BA, dark: 0xD2_A8FF)
        case .inserted: SyntaxColorPair(light: 0x11_6329, dark: 0xAF_F5B4)
        case .deleted: SyntaxColorPair(light: 0x82_071E, dark: 0xFF_DCD7)
        case .plain: nil
        }
    }
}
