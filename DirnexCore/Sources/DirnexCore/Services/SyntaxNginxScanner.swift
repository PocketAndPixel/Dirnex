import Foundation

/// nginx's configuration (docs/HISTORY.md, 2026-09-16).
///
/// Its own scanner rather than a grammar row, because nginx has no reserved words — a directive is
/// whatever word **begins a statement**, after a `;`, a `{` or a `}`. A keyword list of directive
/// names colors them wherever they appear, and they appear in values all the time: `index` in
/// `try_files $uri /index.html`, and `http` in every `proxy_pass http://…`. That is the false positive `CFamilyGrammars.swift` took `prefix` out of Swift's list for, here
/// on nearly every line. Knowing that a word starts a statement is one `Bool`, set by the
/// punctuation before it: a lookbehind of one token, the same as
/// `SyntaxMarkupScanner.scanAttributes`'s, and not the state stack PLAN.md §6 draws the line at.
///
/// The kinds:
/// - **`.keyword`** for a directive, block names included (`http`, `server`, `location`).
/// - **`.typeOrTag`** for a variable, `$host` or `${host}`, wherever it sits in a value. nginx has
///   no other names, and a variable is what a reader looks for in a `proxy_set_header` line.
/// - **`.number`** for a value that starts with a digit: `80`, `10m`, `1.1`, `127.0.0.1:8080`.
/// - **`.string`** and **`.comment`** as everywhere else. A `#` starts a comment only where a word
///   could start, so the `#` inside `http://host/#top` stays part of the word.
enum SyntaxNginxScanner {
    static func tokens(in text: String) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        var scanner = Scanner(units: Array(text.utf16))
        return scanner.run()
    }

    // MARK: - Recognizing a configuration by its contents

    /// Whether `text` reads as nginx configuration: a block opened by one of nginx's own block names
    /// (`server {`, `location /api/ {`), and a statement ending in `;`.
    ///
    /// For the names that do not say so. nginx's files are `default.conf`, `api.conf`, a `default`
    /// with no extension in `sites-available`, or `conf` in a Compose project. Measured 2026-09-16
    /// over the 89 `.conf` files in `/etc`, `/opt/homebrew/etc` and `~/Dev`: this picks out exactly
    /// the 9 nginx files. The block name is what does it — `racoon.conf` ends 30 lines with `;` and
    /// opens 6 blocks, none of them one of nginx's. Apache's `httpd.conf` opens its blocks with
    /// `<VirtualHost>` and ends no line with `;`, fontconfig's is XML, and an HCL `server {` has no
    /// `;` after it.
    ///
    /// Reads at most the first `lineLimit` lines: a real configuration opens a block early, and a
    /// 4 MB log should not be walked to answer.
    static func looksLikeConfiguration(_ text: String) -> Bool {
        var sawBlock = false
        var sawStatement = false
        let lines = text.split(maxSplits: lineLimit, whereSeparator: \.isNewline).prefix(lineLimit)
        for line in lines {
            var content = line.drop { $0 == " " || $0 == "\t" }
            if let hash = content.firstIndex(of: "#") { content = content[..<hash] }
            while let last = content.last, last == " " || last == "\t" { content = content.dropLast() }
            if content.last == ";" {
                sawStatement = true
            } else if content.last == "{",
                      let name = content.split(whereSeparator: { " \t{".contains($0) }).first,
                      blockNames.contains(String(name)) {
                sawBlock = true
            }
            if sawBlock, sawStatement { return true }
        }
        return false
    }

    private static let lineLimit = 500

    /// The blocks that appear in a configuration and in nothing else that ends lines with `;`.
    /// `map`, `if` and `types` are nginx blocks too, and are left out as too common elsewhere to be
    /// evidence.
    private static let blockNames: Set<String> = [
        "events", "http", "location", "server", "stream", "upstream"
    ]

    // MARK: - The scan

    private struct Scanner {
        let units: [UInt16]
        private var index = 0
        private var tokens: [SyntaxToken] = []
        /// Whether the next word begins a statement, which is what makes it a directive.
        private var atStatementStart = true

        init(units: [UInt16]) { self.units = units }

        mutating func run() -> [SyntaxToken] {
            while index < units.count {
                let unit = units[index]
                if Unit.isSpaceOrTab(unit) || Unit.isLineBreak(unit) {
                    index += 1
                } else if unit == Unit.semicolon || unit == Unit.openBrace || unit == Unit.closeBrace {
                    atStatementStart = true
                    index += 1
                } else if unit == Unit.hash {
                    let start = index
                    index = Unit.lineEnd(from: index, in: units)
                    emit(start, index, .comment)
                } else if unit == Unit.doubleQuote || unit == Unit.singleQuote {
                    scanString(quote: unit)
                    atStatementStart = false
                } else {
                    scanWord()
                }
            }
            return tokens
        }

        /// A quoted value, delimiters included. It stops at the line break when it is never closed,
        /// for the reason `LanguageGrammar.StringLiteral.spansLines` gives: a missing quote costs one
        /// line rather than the rest of the file. A `$variable` inside it is left the string's color.
        private mutating func scanString(quote: UInt16) {
            let start = index
            index += 1
            while index < units.count {
                let unit = units[index]
                if unit == Unit.backslash {
                    index = min(index + 2, units.count)
                } else if Unit.isLineBreak(unit) {
                    break
                } else {
                    index += 1
                    if unit == quote { break }
                }
            }
            emit(start, index, .string)
        }

        /// A directive, or a value with its variables marked.
        private mutating func scanWord() {
            let start = index
            let end = wordEnd(from: start)
            index = end
            if atStatementStart {
                atStatementStart = false
                emit(start, end, .keyword)
            } else if Unit.isDigit(units[start]) {
                emit(start, end, .number)
            } else {
                scanVariables(from: start, to: end)
            }
        }

        /// Where the word at `start` ends: at whitespace, or at the punctuation that ends a
        /// statement. A `${name}` keeps its braces, which would otherwise end the word inside it.
        private func wordEnd(from start: Int) -> Int {
            var position = start
            while position < units.count {
                let unit = units[position]
                if unit == Unit.dollar, let close = bracedVariableEnd(from: position) {
                    position = close
                    continue
                }
                if Unit.isSpaceOrTab(unit) || Unit.isLineBreak(unit) || unit == Unit.semicolon
                    || unit == Unit.openBrace || unit == Unit.closeBrace {
                    break
                }
                position += 1
            }
            return position
        }

        /// `$host`, `$1` (a regex capture) and `${host}` inside a value.
        private mutating func scanVariables(from start: Int, to end: Int) {
            var position = start
            while position < end {
                guard units[position] == Unit.dollar else {
                    position += 1
                    continue
                }
                if let close = bracedVariableEnd(from: position), close <= end {
                    emit(position, close, .typeOrTag)
                    position = close
                    continue
                }
                var nameEnd = position + 1
                while nameEnd < end, isNameUnit(units[nameEnd]) { nameEnd += 1 }
                // A `$` with no name after it is a regex anchor: `location ~ \.php$ {`.
                if nameEnd > position + 1 { emit(position, nameEnd, .typeOrTag) }
                position = nameEnd
            }
        }

        /// One past the `}` of a `${name}` opening at `position`, or `nil` if it is not one.
        private func bracedVariableEnd(from position: Int) -> Int? {
            guard position + 1 < units.count, units[position + 1] == Unit.openBrace else { return nil }
            var close = position + 2
            while close < units.count, isNameUnit(units[close]) { close += 1 }
            guard close > position + 2, close < units.count, units[close] == Unit.closeBrace else {
                return nil
            }
            return close + 1
        }

        private func isNameUnit(_ unit: UInt16) -> Bool {
            Unit.isASCIILetter(unit) || Unit.isDigit(unit) || unit == Unit.underscore
        }

        private mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxToken.Kind) {
            guard end > start else { return }
            tokens.append(SyntaxToken(offset: start, length: end - start, kind: kind))
        }
    }
}
