import Foundation

/// Ignore files and `.gitattributes` (docs/HISTORY.md, 2026-09-16).
///
/// Its own scanner rather than a grammar row because of where a comment may start. A `#` is a
/// comment only at the start of a line — `docs#1/` is a pattern — and a grammar's line comment
/// starts wherever its token appears, which would color the rest of that pattern as a comment. The
/// same rule makes a leading `!` mean negation and nothing else. So every decision is made from a
/// line's first character, exactly as in `SyntaxDiffScanner`, and nothing is remembered between
/// lines.
///
/// The kinds:
/// - **`.comment`** for a comment line.
/// - **`.keyword`** for the pattern language's operators: the negating `!` and the glob
///   metacharacters `*`, `**`, `?` and `[…]`. A pattern's literal text stays in the text color, so
///   what reads at a glance is which lines match by name and which by shape.
/// - **`.typeOrTag`** for what `.gitattributes` says about a pattern — an attribute, `-diff`,
///   `!eol` — and for a `CODEOWNERS` owner, which sits in the same place.
/// - **`.string`** for an attribute's value (`eol=lf`, `merge=union`) and for a quoted pattern.
enum SyntaxIgnoreScanner {
    enum Dialect {
        /// `.gitignore` and the formats that copied it: one pattern per line.
        case ignore
        /// `.gitattributes` and `CODEOWNERS`: a pattern, then whitespace-separated words about it.
        case attributes
    }

    static func tokens(in text: String, dialect: Dialect) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        var scanner = Scanner(units: Array(text.utf16), dialect: dialect)
        return scanner.run()
    }

    private struct Scanner {
        let units: [UInt16]
        let dialect: Dialect
        private var tokens: [SyntaxToken] = []

        init(units: [UInt16], dialect: Dialect) {
            self.units = units
            self.dialect = dialect
        }

        mutating func run() -> [SyntaxToken] {
            var lineStart = 0
            while lineStart < units.count {
                let end = Unit.lineEnd(from: lineStart, in: units)
                scanLine(from: lineStart, to: end)
                lineStart = Unit.nextLineStart(after: end, in: units)
            }
            return tokens
        }

        /// One line. Indentation is skipped before the comment test, which is what Docker's reader
        /// does; git's does not, but a pattern that opens with spaces and then a `#` is not one
        /// anybody writes.
        private mutating func scanLine(from start: Int, to end: Int) {
            var position = Unit.firstNonSpace(from: start, upTo: end, in: units)
            guard position < end else { return }
            if units[position] == Unit.hash {
                emit(position, end, .comment)
                return
            }
            switch dialect {
            case .ignore:
                if units[position] == Unit.exclamation {
                    emit(position, position + 1, .keyword)
                    position += 1
                }
                scanPattern(from: position, to: end)
            case .attributes:
                // `.gitattributes` has no negative patterns: a `!` there opens an attribute.
                let patternEnd = fieldEnd(from: position, to: end)
                if units[position] == Unit.doubleQuote {
                    emit(position, patternEnd, .string)
                } else {
                    scanPattern(from: position, to: patternEnd)
                }
                scanAttributes(from: patternEnd, to: end)
            }
        }

        /// The glob metacharacters in a pattern. A backslash makes the next character literal, so
        /// `\*` and `\#` stay in the text color.
        private mutating func scanPattern(from start: Int, to end: Int) {
            var position = start
            while position < end {
                let unit = units[position]
                if unit == Unit.backslash {
                    position += 2
                } else if unit == Unit.asterisk || unit == Unit.question {
                    let runStart = position
                    while position < end,
                          units[position] == Unit.asterisk || units[position] == Unit.question {
                        position += 1
                    }
                    emit(runStart, position, .keyword)
                } else if unit == Unit.openBracket, let close = classEnd(from: position, to: end) {
                    emit(position, close, .keyword)
                    position = close
                } else {
                    position += 1
                }
            }
        }

        /// One past the `]` closing a character class that opens at `start`, or `nil` when the line
        /// has none — a lone `[` is a literal. A `]` straight after `[` or `[!` belongs to the class,
        /// as in `fnmatch`.
        private func classEnd(from start: Int, to end: Int) -> Int? {
            var position = start + 1
            if position < end, units[position] == Unit.exclamation || units[position] == Unit.caret {
                position += 1
            }
            if position < end, units[position] == Unit.closeBracket { position += 1 }
            while position < end {
                if units[position] == Unit.closeBracket { return position + 1 }
                position += 1
            }
            return nil
        }

        /// The words after a `.gitattributes` pattern: `text`, `-diff`, `!eol`, `eol=lf`.
        private mutating func scanAttributes(from start: Int, to end: Int) {
            var position = start
            while position < end {
                if Unit.isSpaceOrTab(units[position]) {
                    position += 1
                    continue
                }
                let fieldStart = position
                let fieldEnd = fieldEnd(from: position, to: end)
                var equals = fieldStart
                while equals < fieldEnd, units[equals] != Unit.equals { equals += 1 }
                emit(fieldStart, equals, .typeOrTag)
                if equals < fieldEnd { emit(equals + 1, fieldEnd, .string) }
                position = fieldEnd
            }
        }

        /// Where the whitespace-separated field at `start` ends. A quoted pattern runs to its closing
        /// quote, spaces included, as git reads one.
        private func fieldEnd(from start: Int, to end: Int) -> Int {
            var position = start
            if units[start] == Unit.doubleQuote {
                position += 1
                while position < end, units[position] != Unit.doubleQuote {
                    position += units[position] == Unit.backslash ? 2 : 1
                }
                return min(position + 1, end)
            }
            while position < end, !Unit.isSpaceOrTab(units[position]) { position += 1 }
            return position
        }

        private mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxToken.Kind) {
            let end = min(end, units.count)
            guard end > start else { return }
            tokens.append(SyntaxToken(offset: start, length: end - start, kind: kind))
        }
    }
}
