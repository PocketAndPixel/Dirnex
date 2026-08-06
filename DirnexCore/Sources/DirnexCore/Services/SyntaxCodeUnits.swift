import Foundation

/// The UTF-16 code units and the line walking every syntax scanner shares (PLAN.md §M17).
///
/// Extracted when Slice 2's three scanners arrived: `private` does not cross files in Swift, so the
/// alternative was three more copies of "is this a digit" — and a fourth copy is exactly how one of
/// them ends up disagreeing about what a line break is.
///
/// Everything here works in **code units**, never in `Character`s. A Swift `Character` is a grapheme
/// cluster, so CRLF is *one* `Character` that equals neither `"\n"` nor `"\r"` (docs/NOTES.md) — a
/// scan built on that finds no line breaks at all in a file written on Windows, and reads as "the
/// parser rejects this format".
enum Unit {
    static let tab: UInt16 = 0x09
    static let lineFeed: UInt16 = 0x0A
    static let carriageReturn: UInt16 = 0x0D
    static let space: UInt16 = 0x20
    static let exclamation: UInt16 = 0x21
    static let doubleQuote: UInt16 = 0x22
    static let hash: UInt16 = 0x23
    static let dollar: UInt16 = 0x24
    static let ampersand: UInt16 = 0x26
    static let singleQuote: UInt16 = 0x27
    static let asterisk: UInt16 = 0x2A
    static let plus: UInt16 = 0x2B
    static let minus: UInt16 = 0x2D
    static let dot: UInt16 = 0x2E
    static let slash: UInt16 = 0x2F
    static let zero: UInt16 = 0x30
    static let nine: UInt16 = 0x39
    static let colon: UInt16 = 0x3A
    static let semicolon: UInt16 = 0x3B
    static let less: UInt16 = 0x3C
    static let equals: UInt16 = 0x3D
    static let greater: UInt16 = 0x3E
    static let question: UInt16 = 0x3F
    static let upperA: UInt16 = 0x41
    static let upperE: UInt16 = 0x45
    static let upperP: UInt16 = 0x50
    static let upperZ: UInt16 = 0x5A
    static let openBracket: UInt16 = 0x5B
    static let backslash: UInt16 = 0x5C
    static let closeBracket: UInt16 = 0x5D
    static let underscore: UInt16 = 0x5F
    static let backtick: UInt16 = 0x60
    static let lowerA: UInt16 = 0x61
    static let lowerE: UInt16 = 0x65
    static let lowerP: UInt16 = 0x70
    static let lowerZ: UInt16 = 0x7A
    static let tilde: UInt16 = 0x7E
    static let openParen: UInt16 = 0x28
    static let closeParen: UInt16 = 0x29
    /// Everything at or above this is left to the identifier rules: a keyword is always ASCII, so
    /// non-ASCII text can only ever be part of a name, and treating it as one is what lets a
    /// Cyrillic or CJK identifier consume itself instead of being scanned unit by unit.
    static let asciiCeiling: UInt16 = 0x80

    // MARK: - Classification

    static func isDigit(_ unit: UInt16) -> Bool { unit >= zero && unit <= nine }

    static func isASCIILetter(_ unit: UInt16) -> Bool {
        (unit >= upperA && unit <= upperZ) || (unit >= lowerA && unit <= lowerZ)
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        isASCIILetter(unit) || unit == underscore || unit == dollar || unit >= asciiCeiling
    }

    static func isIdentifierContinue(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }

    static func isLineBreak(_ unit: UInt16) -> Bool { unit == lineFeed || unit == carriageReturn }

    static func isSpaceOrTab(_ unit: UInt16) -> Bool { unit == space || unit == tab }

    /// The letter that lets a sign continue a number: `1e-9`, and `0x1p-3` for a hex float.
    static func isExponentMarker(_ unit: UInt16) -> Bool {
        unit == lowerE || unit == upperE || unit == lowerP || unit == upperP
    }

    // MARK: - Matching and lines

    /// Whether `units` carries `pattern` starting at `index`. An empty pattern never matches, so a
    /// grammar with a field left unset can never claim a position.
    static func matches(_ pattern: [UInt16], in units: [UInt16], at index: Int) -> Bool {
        guard !pattern.isEmpty, index + pattern.count <= units.count else { return false }
        for offset in 0..<pattern.count where units[index + offset] != pattern[offset] {
            return false
        }
        return true
    }

    /// Where the line containing `index` ends — the position of its first line-break unit, or the
    /// end of the buffer for a final line with no terminator.
    static func lineEnd(from index: Int, in units: [UInt16]) -> Int {
        var end = index
        while end < units.count, !isLineBreak(units[end]) { end += 1 }
        return end
    }

    /// Where the next line begins, given the `end` returned above. CRLF counts as **one** break, so
    /// a Windows file does not report an empty line between every pair of real ones.
    static func nextLineStart(after end: Int, in units: [UInt16]) -> Int {
        guard end < units.count else { return units.count }
        if units[end] == carriageReturn, end + 1 < units.count, units[end + 1] == lineFeed {
            return end + 2
        }
        return end + 1
    }

    /// The first unit of the line's content, skipping its indentation.
    static func firstNonSpace(from index: Int, upTo end: Int, in units: [UInt16]) -> Int {
        var position = index
        while position < end, isSpaceOrTab(units[position]) { position += 1 }
        return position
    }

    /// A convenience for the literal patterns the scanners compare against.
    static func pattern(_ text: String) -> [UInt16] { Array(text.utf16) }
}
