import Foundation

/// The text rules of the bug-report contract (PLAN.md §M30), written out so Swift and the server's
/// TypeScript give the same answer. Library defaults disagree here: `Character.isWhitespace` misses
/// U+FEFF and counts U+0085, which JavaScript's `trim` does the other way round, and `\s` means
/// different things in the two regex engines (docs/NOTES.md ▸ License keys: one format, two
/// languages).
public enum BugReportText {
    /// What a blank text is made of: exactly the characters JavaScript's `String.prototype.trim`
    /// removes, since that is what the server checks with. The shared cases carry the same list, and
    /// the server's tests check it still equals `trim`.
    public static let blankScalars: Set<Unicode.Scalar> = [
        "\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}", "\u{20}", "\u{A0}", "\u{1680}",
        "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}",
        "\u{2007}", "\u{2008}", "\u{2009}", "\u{200A}", "\u{2028}", "\u{2029}", "\u{202F}",
        "\u{205F}", "\u{3000}", "\u{FEFF}"
    ]

    /// Whether `text` has nothing but ``blankScalars``. An empty text is blank.
    public static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(blankScalars.contains)
    }

    /// `text` without ``blankScalars`` at either end.
    public static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let isText = { (scalar: Unicode.Scalar) in !blankScalars.contains(scalar) }
        guard let first = scalars.firstIndex(where: isText),
              let last = scalars.lastIndex(where: isText)
        else {
            return ""
        }
        return String(Substring(scalars[first...last]))
    }

    /// `text` as it was, or `nil` when it is missing or blank: the body leaves those out.
    public static func nonBlank(_ text: String?) -> String? {
        guard let text, !isBlank(text) else { return nil }
        return text
    }

    /// Whether `text` looks like an email address. Deliberately loose, and the same rule as the
    /// server's:
    /// - exactly one `@`, with something before it;
    /// - after it, a domain with a `.` that is neither its first nor its last character;
    /// - no space or control character (U+0000–U+0020, U+007F) anywhere.
    ///
    /// It walks Unicode scalars, not `Character`s: an `@` followed by a combining mark is one
    /// `Character` that is not equal to `"@"` (a shared case pins it).
    public static func isEmailShaped(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard let at = scalars.firstIndex(of: "@"), at > 0, scalars.lastIndex(of: "@") == at else {
            return false
        }
        let domain = scalars[(at + 1)...]
        guard domain.contains("."), domain.first != ".", domain.last != "." else { return false }
        return !scalars.contains { $0.value <= 0x20 || $0.value == 0x7F }
    }

    /// The longest start of `text` that fits in `maxBytes` of UTF-8, cut between characters, so no
    /// letter loses its accent and no emoji is split.
    ///
    /// It jumps to the byte and steps back to the nearest character boundary, so a crash report of
    /// a megabyte costs the length of one character rather than a walk over the whole text.
    public static func prefix(_ text: String, maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        guard maxBytes > 0 else { return "" }
        var end = text.utf8.index(text.startIndex, offsetBy: maxBytes)
        while end > text.startIndex, end.samePosition(in: text) == nil {
            end = text.utf8.index(before: end)
        }
        return String(text[..<end])
    }
}
