import Foundation

/// `.env` files (docs/HISTORY.md, 2026-09-16).
///
/// Its own scanner rather than a grammar row because what a reader looks for in one is the key, and
/// a key is a key only by its place — before the `=` — which no word list can say. A grammar would
/// color the comments and the quoted values and leave `DATABASE_URL=postgres://…` one color. So it
/// reads each line as `[export] KEY=value [# comment]`, the shape every dotenv library accepts,
/// and colors the key as `.keyword` and the value as `.string`, the kinds
/// `SyntaxMarkupScanner` gives an attribute's name and its value.
///
/// An unquoted value runs to the end of its line, or to a `#` with whitespace before it, so
/// `Host=db;Port=5432` and `color=#fff` are whole values. A quoted value runs to its closing quote
/// **across lines**, because a private key in double quotes is an ordinary `.env` value — and
/// unlike a grammar's literal, this one can only be opened by a quote that *starts* a value, so the
/// apostrophe in `NAME=don't` cannot open one and color the rest of the file.
enum SyntaxDotenvScanner {
    static func tokens(in text: String) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        var scanner = Scanner(units: Array(text.utf16))
        return scanner.run()
    }

    private static let export = Unit.pattern("export")

    private struct Scanner {
        let units: [UInt16]
        private var index = 0
        private var tokens: [SyntaxToken] = []

        init(units: [UInt16]) { self.units = units }

        mutating func run() -> [SyntaxToken] {
            while index < units.count {
                scanLine()
                // A quoted value may have carried the scan onto a later line; the next line starts
                // after whichever line it ended on.
                index = Unit.nextLineStart(after: Unit.lineEnd(from: index, in: units), in: units)
            }
            return tokens
        }

        private mutating func scanLine() {
            let end = Unit.lineEnd(from: index, in: units)
            index = Unit.firstNonSpace(from: index, upTo: end, in: units)
            guard index < end else { return }
            if units[index] == Unit.hash {
                emit(index, end, .comment)
                index = end
                return
            }
            let afterExport = index + SyntaxDotenvScanner.export.count
            if Unit.matches(SyntaxDotenvScanner.export, in: units, at: index), afterExport < end,
               Unit.isSpaceOrTab(units[afterExport]) {
                emit(index, afterExport, .keyword)
                index = Unit.firstNonSpace(from: afterExport, upTo: end, in: units)
            }
            let keyStart = index
            while index < end, isKeyUnit(units[index]) { index += 1 }
            let keyEnd = index
            index = Unit.firstNonSpace(from: index, upTo: end, in: units)
            // Not `KEY=`: a line no dotenv reader accepts, which stays in the text color.
            guard keyEnd > keyStart, index < end, units[index] == Unit.equals else {
                index = end
                return
            }
            emit(keyStart, keyEnd, .keyword)
            scanValue(from: index + 1, lineEnd: end)
        }

        /// The value after the `=`, and a comment after it.
        private mutating func scanValue(from valueStart: Int, lineEnd end: Int) {
            index = Unit.firstNonSpace(from: valueStart, upTo: end, in: units)
            guard index < end else { return }
            let first = units[index]
            if first == Unit.doubleQuote || first == Unit.singleQuote || first == Unit.backtick {
                scanQuoted(quote: first)
                scanTrailingComment()
                return
            }
            // `KEY= # note` is an empty value and a comment; `KEY=#fff` is a value.
            if first == Unit.hash, index > valueStart {
                emit(index, end, .comment)
                index = end
                return
            }
            let start = index
            var valueEnd = index
            while index < end {
                let unit = units[index]
                if unit == Unit.hash, Unit.isSpaceOrTab(units[index - 1]) { break }
                if !Unit.isSpaceOrTab(unit) { valueEnd = index + 1 }
                index += 1
            }
            emit(start, valueEnd, .string)
            emit(index, end, .comment)
            index = end
        }

        /// A quoted value, delimiters included, to its closing quote or the end of the buffer.
        /// Only double quotes take a backslash escape, as in the dotenv libraries.
        private mutating func scanQuoted(quote: UInt16) {
            let start = index
            index += 1
            while index < units.count {
                let unit = units[index]
                if unit == Unit.backslash, quote == Unit.doubleQuote {
                    index = min(index + 2, units.count)
                } else {
                    index += 1
                    if unit == quote { break }
                }
            }
            emit(start, index, .string)
        }

        /// A `# comment` after a quoted value, on the line the value closed on.
        private mutating func scanTrailingComment() {
            let end = Unit.lineEnd(from: index, in: units)
            let content = Unit.firstNonSpace(from: index, upTo: end, in: units)
            if content < end, units[content] == Unit.hash { emit(content, end, .comment) }
            index = end
        }

        /// What a key is spelled with. Dots and dashes are not portable to a shell, and are accepted
        /// by enough readers (`spring.datasource.url`) to be worth coloring.
        private func isKeyUnit(_ unit: UInt16) -> Bool {
            Unit.isASCIILetter(unit) || Unit.isDigit(unit) || unit == Unit.underscore
                || unit == Unit.dot || unit == Unit.minus
        }

        private mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxToken.Kind) {
            guard end > start else { return }
            tokens.append(SyntaxToken(offset: start, length: end - start, kind: kind))
        }
    }
}
