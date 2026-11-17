import Foundation

/// How a file name is drawn on one line when the name itself carries a control character.
///
/// **A single-line label still breaks at a hard line break.** Probed 2026-11-17 on a label built the
/// way the pane's name cell is (`labelWithString:`, `usesSingleLineMode`, truncating tail, `wraps`
/// false): `Icon` lays out 16 pt tall, and `Icon\r`, `Icon\r\n`, `a\nb` and a name holding U+2028 all
/// lay out **32 pt** — two lines in a row one line high, centered, so the visible text rides up and is
/// clipped at the top while the rest of the name is not shown at all. A tab does not break the line
/// but draws as a wide gap. Neither property whose name sounds like the fix stops it.
///
/// The name that showed it is a real one every Mac has: `Icon\r`, the zero-byte file holding a
/// folder's custom icon in its resource fork. OneDrive writes one into the root of its folder, so the
/// row appears as soon as hidden files are shown there.
///
/// **Each control character is drawn as its Unicode control picture** — `Icon\r` as `Icon␍`, a tab
/// as `␉`, DEL as `␡` — the convention editors use to show an invisible character rather than drop
/// it. U+0085, U+2028 and U+2029 have no picture of their own and break a line just the same, so they
/// draw as `␤` (SYMBOL FOR NEWLINE). The pictures are drawn from Apple Symbols by font fallback, and
/// `Icon␍` lays out as one 16 pt line.
///
/// **This is a display form, never a name.** Every verb still addresses the entry by its real name;
/// a caller that reads the drawn text back — the inline rename's field — has to compare against this
/// form, not the real name, to tell an unchanged edit from a rename.
public enum FileNameDisplay {
    /// `name` with every control character replaced by a visible stand-in; `name` itself, unchanged
    /// and without a copy, when it has none (nearly every name).
    public static func visible(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { picture(for: $0) != nil }) else { return name }
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            scalars.append(picture(for: scalar) ?? scalar)
        }
        return String(scalars)
    }

    /// The stand-in for one scalar, or `nil` when it draws as itself.
    ///
    /// By scalar, not by `Character`: `\r\n` is a single `Character` in Swift, and both halves of it
    /// have to show.
    private static func picture(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        switch scalar.value {
        // C0 controls: U+2400 ␀ through U+241F ␟ sit in the same order.
        case 0x00...0x1F: Unicode.Scalar(0x2400 + scalar.value)
        case 0x7F: "\u{2421}" // ␡
        // NEXT LINE, LINE SEPARATOR, PARAGRAPH SEPARATOR: no picture of their own, and each one ends
        // the line in a text field.
        case 0x85, 0x2028, 0x2029: "\u{2424}" // ␤
        default: nil
        }
    }
}
