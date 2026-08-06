import Foundation

/// HTML entities in Markdown source (PLAN.md §M18 ▸ Slice 1).
///
/// Decoded to the character they name rather than passed through, and that is the whole design:
/// the model then holds real text, and the renderer escapes *everything* on the way out with no
/// exception to get wrong. Passing `&nbsp;` through as raw HTML would mean the renderer had a hole
/// in it that something else could be pushed through.
///
/// The named table is short on purpose. The full HTML5 list is ~2 200 names and needs a generated
/// file; these are the ones a `.md` actually carries, and an unrecognized name stays literal text —
/// `&foo;` renders as `&foo;`, which is what it looks like in every editor anyway.
enum MarkdownEntity {
    /// Decode the entity starting at `index` (which must be `&`), and answer it with the number of
    /// characters it occupied.
    static func decode(_ characters: [Character], at index: Int) -> (Character, Int)? {
        guard characters[index] == "&" else { return nil }
        // Long enough for `&thetasym;`, short enough that a stray `&` in prose costs one scan.
        let limit = min(index + 12, characters.count)
        guard let semicolon = characters[index..<limit].firstIndex(of: ";") else { return nil }
        let body = String(characters[(index + 1)..<semicolon])
        guard !body.isEmpty else { return nil }
        let length = semicolon - index + 1
        if body.hasPrefix("#") {
            return numeric(body.dropFirst()).map { ($0, length) }
        }
        return named[body].map { ($0, length) }
    }

    private static func numeric(_ body: Substring) -> Character? {
        let isHex = body.first == "x" || body.first == "X"
        let digits = isHex ? body.dropFirst() : body
        guard !digits.isEmpty, digits.count <= 7 else { return nil }
        guard let value = UInt32(digits, radix: isHex ? 16 : 10) else { return nil }
        // A NUL decoded into the document would be a character no view can draw and one that ends
        // a C string somewhere downstream. CommonMark substitutes the replacement character.
        guard value != 0, let scalar = Unicode.Scalar(value) else { return "\u{FFFD}" }
        return Character(scalar)
    }

    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "check": "✓", "cross": "✗", "dagger": "†", "sect": "§", "para": "¶",
        "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "micro": "µ"
    ]
}
