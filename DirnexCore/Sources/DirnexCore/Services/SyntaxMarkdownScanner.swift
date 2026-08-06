import Foundation

/// Markdown (PLAN.md §M17 ▸ Slice 2).
///
/// Line-oriented, which is what makes it cheap: a heading, a blockquote, a list marker and a
/// thematic break are all decided from the first characters of a line, and only the **code fence**
/// spans lines. Inline constructs are then scanned within the line and never across it, so an
/// unclosed `*` costs its own line rather than the rest of the document — the same bound the source
/// scanner puts on an unterminated quote.
///
/// The kinds, and the reasoning for each: a **heading** is `.keyword` and a **thematic break** is
/// too, because both are the document's own structure; a **blockquote** is `.comment`, being an
/// aside; **code** — span or fence — is `.string`, being literal text; a **list marker** is
/// `.number`, which is what an ordered one literally is; and **emphasis** and a **link's text** are
/// `.typeOrTag`, the remaining bucket, with the link's URL taking `.string` beside it.
///
/// Two constructs are deliberately absent, both because they need to remember a *previous* line:
/// the **setext heading** (text underlined with `===`) and the **indented code block**, which is
/// only code when a blank line precedes it. Each is a wrong colour at worst, never a wrong
/// character (PLAN.md §6).
enum SyntaxMarkdownScanner {
    static func tokens(in text: String) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        var scanner = Scanner(units: Array(text.utf16))
        return scanner.run()
    }

    private struct Scanner {
        let units: [UInt16]
        private var tokens: [SyntaxToken] = []

        init(units: [UInt16]) { self.units = units }

        mutating func run() -> [SyntaxToken] {
            var lineStart = 0
            while lineStart < units.count { lineStart = scanLine(from: lineStart) }
            return tokens
        }

        /// One line — or, for a fence, one block. Returns where scanning continues.
        private mutating func scanLine(from lineStart: Int) -> Int {
            let end = Unit.lineEnd(from: lineStart, in: units)
            let content = Unit.firstNonSpace(from: lineStart, upTo: end, in: units)
            guard content < end else { return Unit.nextLineStart(after: end, in: units) }

            if let afterFence = scanFence(from: content, lineEnd: end) { return afterFence }
            let next = Unit.nextLineStart(after: end, in: units)
            if headingEnd(from: content, to: end) != nil {
                emit(content, end, .keyword)
                return next
            }
            if isThematicBreak(from: content, to: end) {
                emit(content, end, .keyword)
                return next
            }
            if units[content] == Unit.greater {
                emit(content, end, .comment)
                return next
            }
            var cursor = content
            if let marker = listMarkerEnd(from: content, to: end) {
                emit(content, marker, .number)
                cursor = marker
            }
            scanInline(from: cursor, to: end)
            return next
        }

        // MARK: Block constructs

        /// A fenced code block, from its opening fence to the end of the matching closing one — or
        /// to the end of the buffer when it is never closed, which is what a truncated file hands
        /// over. The closer must be the same character, so a ``` block containing `~~~` survives.
        private mutating func scanFence(from content: Int, lineEnd: Int) -> Int? {
            guard let fence = fenceCharacter(at: content, upTo: lineEnd) else { return nil }
            var cursor = Unit.nextLineStart(after: lineEnd, in: units)
            while cursor < units.count {
                let end = Unit.lineEnd(from: cursor, in: units)
                let lineContent = Unit.firstNonSpace(from: cursor, upTo: end, in: units)
                if fenceCharacter(at: lineContent, upTo: end) == fence {
                    emit(content, end, .string)
                    return Unit.nextLineStart(after: end, in: units)
                }
                cursor = Unit.nextLineStart(after: end, in: units)
            }
            emit(content, units.count, .string)
            return units.count
        }

        /// The fence character when at least three of it open the line, else `nil`.
        private func fenceCharacter(at content: Int, upTo end: Int) -> UInt16? {
            guard content < end else { return nil }
            let unit = units[content]
            guard unit == Unit.backtick || unit == Unit.tilde else { return nil }
            var run = 0
            while content + run < end, units[content + run] == unit { run += 1 }
            return run >= 3 ? unit : nil
        }

        /// `#` … `######`, which must be followed by a space or by the end of the line.
        private func headingEnd(from content: Int, to end: Int) -> Int? {
            guard units[content] == Unit.hash else { return nil }
            var run = 0
            while content + run < end, units[content + run] == Unit.hash, run < 7 { run += 1 }
            guard run <= 6 else { return nil }
            let after = content + run
            guard after == end || Unit.isSpaceOrTab(units[after]) else { return nil }
            return after
        }

        /// Three or more `-`, `*` or `_`, alone on the line but for spaces. Tested **before** the
        /// list marker, or `---` reads as a bullet with no content.
        private func isThematicBreak(from content: Int, to end: Int) -> Bool {
            let unit = units[content]
            guard unit == Unit.minus || unit == Unit.asterisk || unit == Unit.underscore else {
                return false
            }
            var count = 0
            for position in content..<end {
                if units[position] == unit {
                    count += 1
                } else if !Unit.isSpaceOrTab(units[position]) {
                    return false
                }
            }
            return count >= 3
        }

        /// `- `, `* `, `+ `, `1. ` or `1) ` — the marker only, never the space after it.
        private func listMarkerEnd(from content: Int, to end: Int) -> Int? {
            let unit = units[content]
            if unit == Unit.minus || unit == Unit.asterisk || unit == Unit.plus {
                guard content + 1 < end, Unit.isSpaceOrTab(units[content + 1]) else { return nil }
                return content + 1
            }
            guard Unit.isDigit(unit) else { return nil }
            var position = content
            while position < end, Unit.isDigit(units[position]) { position += 1 }
            guard position < end, units[position] == Unit.dot || units[position] == Unit.closeParen
            else { return nil }
            position += 1
            guard position < end, Unit.isSpaceOrTab(units[position]) else { return nil }
            return position
        }

        // MARK: Inline constructs

        /// Code spans, emphasis and links, within one line. Anything whose closer is not on the
        /// same line colours nothing at all — silence beats painting the paragraph.
        private mutating func scanInline(from start: Int, to end: Int) {
            var position = start
            while position < end {
                let unit = units[position]
                if unit == Unit.backtick {
                    position = scanCodeSpan(from: position, to: end)
                } else if unit == Unit.asterisk || unit == Unit.underscore {
                    position = scanEmphasis(from: position, to: end)
                } else if unit == Unit.openBracket {
                    position = scanLink(from: position, to: end)
                } else {
                    position += 1
                }
            }
        }

        /// A code span closes on a backtick run of the **same** length, which is what lets
        /// ``` ``a `b` c`` ``` hold a backtick.
        private mutating func scanCodeSpan(from start: Int, to end: Int) -> Int {
            let opener = runLength(of: Unit.backtick, from: start, to: end)
            var position = start + opener
            while position < end {
                guard units[position] == Unit.backtick else {
                    position += 1
                    continue
                }
                let closer = runLength(of: Unit.backtick, from: position, to: end)
                guard closer == opener else {
                    position += closer
                    continue
                }
                emit(start, position + closer, .string)
                return position + closer
            }
            return start + opener
        }

        /// `*a*`, `**a**`, `_a_`. Both flanking rules are enforced, and each removes a false
        /// positive that a Markdown file really does contain: a delimiter may not be followed by a
        /// space (so `2 * 3 * 4` is arithmetic, not emphasis) and a closer may not be preceded by
        /// one.
        private mutating func scanEmphasis(from start: Int, to end: Int) -> Int {
            let marker = units[start]
            let opener = runLength(of: marker, from: start, to: end)
            // CommonMark ignores an intraword `_`, so `report_2026_final` stays plain. It is the
            // one of the two markers where that holds — the same asymmetry NOTES.md ▸ Localization
            // measured from the other direction, where `*.jpg;*.png` lost its asterisks.
            if marker == Unit.underscore, start > 0, Unit.isIdentifierContinue(units[start - 1]) {
                return start + opener
            }
            var position = start + opener
            guard position < end, !Unit.isSpaceOrTab(units[position]) else { return position }
            while position < end {
                guard units[position] == marker, !Unit.isSpaceOrTab(units[position - 1]) else {
                    position += 1
                    continue
                }
                let closer = runLength(of: marker, from: position, to: end)
                emit(start, position + min(closer, opener), .typeOrTag)
                return position + closer
            }
            return start + opener
        }

        /// `[text](url)`, and the `[text]` of a reference link on its own.
        private mutating func scanLink(from start: Int, to end: Int) -> Int {
            var position = start + 1
            while position < end, units[position] != Unit.closeBracket { position += 1 }
            guard position < end else { return start + 1 }
            let textEnd = position + 1
            emit(start, textEnd, .typeOrTag)
            guard textEnd < end, units[textEnd] == Unit.openParen else { return textEnd }
            position = textEnd + 1
            while position < end, units[position] != Unit.closeParen { position += 1 }
            guard position < end else { return textEnd }
            emit(textEnd, position + 1, .string)
            return position + 1
        }

        // MARK: Primitives

        private func runLength(of unit: UInt16, from start: Int, to end: Int) -> Int {
            var run = 0
            while start + run < end, units[start + run] == unit { run += 1 }
            return run
        }

        private mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxToken.Kind) {
            let bounded = min(end, units.count)
            guard bounded > start else { return }
            tokens.append(SyntaxToken(offset: start, length: bounded - start, kind: kind))
        }
    }
}
