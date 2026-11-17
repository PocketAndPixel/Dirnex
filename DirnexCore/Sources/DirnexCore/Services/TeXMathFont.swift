import Foundation

/// `\mathbf`, `\mathbb` and the other font commands, as the characters Unicode gives each style
/// (PLAN.md §M39 ▸ Slice 8).
///
/// MathML Core keeps `mathvariant` for `normal` only, so a style is written as the character
/// itself: `\mathbb{R}` is `ℝ` and `\mathbf{x}` is `𝐱`, which WebKit draws from the math font
/// (probed 2026-11-14). The Mathematical Alphanumeric Symbols block leaves a hole wherever the
/// Letterlike Symbols block already had the letter, so `ℝ` is U+211D rather than the block's
/// U+1D549, and the tables below fill each hole from there.
enum TeXMathFont: Equatable {
    /// `\mathrm`: upright, which a one-letter `<mi>` needs `mathvariant="normal"` for.
    case roman
    case bold
    case italic
    case boldItalic
    case script
    case fraktur
    case doubleStruck
    case sansSerif
    case monospace

    /// The commands that take an argument in this font.
    static let commands: [String: TeXMathFont] = [
        "mathrm": .roman, "mathup": .roman, "mathbf": .bold, "mathit": .italic,
        "boldsymbol": .boldItalic, "bm": .boldItalic, "mathbfit": .boldItalic,
        "mathcal": .script, "mathscr": .script, "mathfrak": .fraktur, "mathbb": .doubleStruck,
        "mathsf": .sansSerif, "mathtt": .monospace
    ]

    /// The old switches that set the font for the rest of their group, `{\bf x}`.
    static let switches: [String: TeXMathFont] = [
        "rm": .roman, "bf": .bold, "it": .italic, "cal": .script, "sf": .sansSerif,
        "tt": .monospace
    ]

    /// The text commands, `\textbf{…}`, and the font their text takes.
    static let textCommands: [String: TeXMathFont?] = [
        "text": nil, "textrm": nil, "textup": nil, "textnormal": nil, "mbox": nil, "hbox": nil,
        "textbf": .bold, "textit": .italic, "textsf": .sansSerif, "texttt": .monospace
    ]

    /// `character` in this font, or itself when the font has no such character: punctuation, a
    /// letter outside Latin and Greek, a digit in a font without digits.
    func styled(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              let mapped = styled(scalar.value)
        else { return character }
        return Character(mapped)
    }

    private func styled(_ value: UInt32) -> Unicode.Scalar? {
        if let hole = holes[value] { return Unicode.Scalar(hole) }
        let base: UInt32?
        switch value {
        case 0x41...0x5A: base = latin.map { $0 + value - 0x41 }
        case 0x61...0x7A: base = latin.map { $0 + 26 + value - 0x61 }
        case 0x30...0x39: base = digits.map { $0 + value - 0x30 }
        case 0x391...0x3A9: base = greek.map { $0 + value - 0x391 }
        case 0x3B1...0x3C9: base = greek.map { $0 + 26 + value - 0x3B1 }
        default: base = nil
        }
        return base.flatMap(Unicode.Scalar.init)
    }

    /// Where the font's capital A is; its small a follows 26 places on.
    private var latin: UInt32? {
        switch self {
        case .roman: nil
        case .bold: 0x1D400
        case .italic: 0x1D434
        case .boldItalic: 0x1D468
        case .script: 0x1D49C
        case .fraktur: 0x1D504
        case .doubleStruck: 0x1D538
        case .sansSerif: 0x1D5A0
        case .monospace: 0x1D670
        }
    }

    private var digits: UInt32? {
        switch self {
        case .bold: 0x1D7CE
        case .doubleStruck: 0x1D7D8
        case .sansSerif: 0x1D7E2
        case .monospace: 0x1D7F6
        default: nil
        }
    }

    /// Where the font's capital Alpha is. The block keeps Greek's own order, `ϴ` included where
    /// U+03A2 has no letter, so small alpha is 26 places on here too.
    private var greek: UInt32? {
        switch self {
        case .bold: 0x1D6A8
        case .italic: 0x1D6E2
        case .boldItalic: 0x1D71C
        default: nil
        }
    }

    private var holes: [UInt32: UInt32] {
        switch self {
        case .italic: [0x68: 0x210E]
        case .script: [
                0x42: 0x212C, 0x45: 0x2130, 0x46: 0x2131, 0x48: 0x210B, 0x49: 0x2110,
                0x4C: 0x2112, 0x4D: 0x2133, 0x52: 0x211B, 0x65: 0x212F, 0x67: 0x210A,
                0x6F: 0x2134
            ]
        case .fraktur: [0x43: 0x212D, 0x48: 0x210C, 0x49: 0x2111, 0x52: 0x211C, 0x5A: 0x2128]
        case .doubleStruck: [
                0x43: 0x2102, 0x48: 0x210D, 0x4E: 0x2115, 0x50: 0x2119, 0x51: 0x211A,
                0x52: 0x211D, 0x5A: 0x2124
            ]
        default: [:]
        }
    }
}
