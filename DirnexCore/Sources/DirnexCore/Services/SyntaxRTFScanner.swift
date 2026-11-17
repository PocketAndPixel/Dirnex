import Foundation

/// An RTF file's own text, colored (PLAN.md §M39 ▸ Slice 3): the source style of the fifth
/// dual-style family, whose page is the document `NSAttributedString` reads.
///
/// RTF is nothing but a control-word language, so the scanner is its lexical grammar and no more:
///
/// - **A control word** — a backslash and ASCII letters, `\fs`, `\cf`, `\pard` — is a keyword, and
///   the signed number that may follow it (`24` in `\fs24`, `-360` in `\fi-360`) a number. The one
///   space that may end a control word is its delimiter, and stays uncolored like any other.
/// - **A control symbol that stands for a character** — `\'e9`, `\\`, `\{`, `\}`, and the non-breaking
///   space and the two hyphens (`\~`, `\-`, `\_`) — is a string: what the document says, written so the
///   syntax lets it through. Every other control symbol is a keyword, among them a backslash that
///   ends a line, which is a paragraph mark, and is how every Cocoa writer ends a paragraph.
/// - **A brace** opens or closes a group, which is the only structure RTF has, so it takes the tag
///   color.
/// - **A group the writer marked ignorable** — `{\*\generator …}`, `{\*\expandedcolortbl …}`, Word's
///   `{\*\panose …}`, `{\*\themedata …}` and `{\*\datastore …}` — is a comment, braces included. That
///   is the spec's own word for it: a reader that does not know the destination skips the group
///   whole. It is most of a Word file's bytes and none of its text, so it is the one thing this
///   scanner does that a reader would miss if it were left out.
///
/// Everything else is the document's text, or a destination's data (a font's name, a color table's
/// `;`), and is left in the view's own color.
///
/// One pass, and the only thing remembered is a nesting depth while an ignorable group is skipped —
/// a counter, as `SyntaxHighlighter` allows, not a stack of contexts. So a construct this misreads is
/// a wrong color and never a wrong character, and the honest limits are named rather than handled:
///
/// - **`\binN`** is followed by N raw bytes, which may hold a brace or a backslash. None of the 1 779
///   RTF files on the development Mac carries one (measured 2026-11-12), and a file that did would hold
///   bytes no text decoding takes, so it would reach Quick Look before it reached this scanner.
/// - **A picture's hex** (`{\pict … 89504e47…}`) is data, and is drawn as text. Telling it apart needs
///   the group's destination remembered, which is a second piece of state for a run of digits; Word
///   writes most of its pictures inside `{\*\shppict …}`, which is a comment already.
/// - **An ignorable group whose `\*` does not follow its brace directly** — a line break between them,
///   which the spec allows and no writer surveyed does — is colored as an ordinary group.
enum SyntaxRTFScanner {
    static func tokens(in text: String) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        var scan = Scan(units: Array(text.utf16))
        scan.run()
        return scan.tokens
    }

    private struct Scan {
        let units: [UInt16]
        var tokens: [SyntaxToken] = []
        private var index = 0

        init(units: [UInt16]) {
            self.units = units
        }

        mutating func run() {
            while index < units.count {
                switch units[index] {
                case Unit.openBrace where opensIgnorableGroup(at: index):
                    let end = groupEnd(from: index)
                    emit(index, end, .comment)
                    index = end
                case Unit.openBrace, Unit.closeBrace:
                    emit(index, index + 1, .typeOrTag)
                    index += 1
                case Unit.backslash:
                    index = controlSequence(at: index)
                default:
                    index += 1
                }
            }
        }

        /// `{\*` — the opening of a group a reader may skip whole.
        private func opensIgnorableGroup(at start: Int) -> Bool {
            start + 2 < units.count && units[start + 1] == Unit.backslash
                && units[start + 2] == Unit.asterisk
        }

        /// One past the brace that closes the group opening at `start`, or the end of the text for a
        /// group that never closes — a truncated preview, or a broken file, both of which leave the
        /// rest of it in the comment rather than guess where the group was meant to end.
        ///
        /// A backslash takes the unit after it with it, which is what keeps `\{`, `\}` and `\\` from
        /// counting. A control word's letters are never braces, so skipping only its first one is
        /// enough.
        private func groupEnd(from start: Int) -> Int {
            var depth = 0
            var position = start
            while position < units.count {
                switch units[position] {
                case Unit.backslash:
                    position += 2
                    continue
                case Unit.openBrace:
                    depth += 1
                case Unit.closeBrace:
                    depth -= 1
                    if depth == 0 { return position + 1 }
                default:
                    break
                }
                position += 1
            }
            return units.count
        }

        /// Color the control word or control symbol starting at the backslash at `start`, and return
        /// where scanning resumes.
        private mutating func controlSequence(at start: Int) -> Int {
            let next = start + 1
            // A backslash ending the text is left alone: what it was going to escape was cut off.
            guard next < units.count else { return units.count }
            let unit = units[next]
            if Unit.isASCIILetter(unit) {
                return controlWord(at: start)
            }
            switch unit {
            case Unit.singleQuote:
                // `\'hh`: a byte in the document's code page. Up to two hex digits are part of it.
                var end = next + 1
                while end < units.count, end < next + 3, Unit.isHexDigit(units[end]) { end += 1 }
                emit(start, end, .string)
                return end
            case Unit.backslash, Unit.openBrace, Unit.closeBrace, Unit.tilde, Unit.minus,
                 Unit.underscore:
                emit(start, next + 1, .string)
                return next + 1
            case Unit.lineFeed, Unit.carriageReturn:
                // `\` before a line break is `\par`. The break itself is not part of the mark, and
                // coloring it would color nothing visible.
                emit(start, next, .keyword)
                return next
            default:
                emit(start, next + 1, .keyword)
                return next + 1
            }
        }

        /// `\word` and its optional signed parameter, `\fs24` or `\li-360`.
        private mutating func controlWord(at start: Int) -> Int {
            var end = start + 1
            while end < units.count, Unit.isASCIILetter(units[end]) { end += 1 }
            emit(start, end, .keyword)
            var digits = end
            if digits < units.count, units[digits] == Unit.minus,
               digits + 1 < units.count, Unit.isDigit(units[digits + 1]) {
                digits += 1
            }
            guard digits < units.count, Unit.isDigit(units[digits]) else { return end }
            while digits < units.count, Unit.isDigit(units[digits]) { digits += 1 }
            emit(end, digits, .number)
            return digits
        }

        private mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxToken.Kind) {
            guard end > start else { return }
            tokens.append(SyntaxToken(offset: start, length: end - start, kind: kind))
        }
    }
}
