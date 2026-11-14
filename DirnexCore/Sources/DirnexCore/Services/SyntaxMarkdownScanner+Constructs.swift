import Foundation

/// The constructs `SyntaxMarkdownScanner` reads within a line, and the fenced block, which it reads
/// as one (PLAN.md §M17 ▸ Slice 2). Moved out of the scanner's own file when Slice 9 of M39 gave it
/// the state a setext heading and an indented code block need, to keep the type under SwiftLint's
/// `type_body_length`.
extension SyntaxMarkdownScanner.Scanner {
    // MARK: Block constructs

    /// A fenced code block, from its opening fence to the end of the matching closing one — or
    /// to the end of the buffer when it is never closed, which is what a truncated file hands
    /// over. CommonMark's closer: the same character, at least as many of it, nothing after but
    /// spaces, and fewer than `closerIndent` columns in. So a ```` block can show a ``` block
    /// inside it, a ``` block containing `~~~` survives, and a ``` line four columns into a list
    /// item's indented code is that code's own text.
    ///
    /// **Three tokens, not one.** The two fence *lines* take `.keyword`, on the heading's
    /// argument — they are the document's own structure — and the block's **content** is
    /// scanned as the language its info string names, or left entirely uncolored when it names
    /// none. That is what VS Code shows and what the block wants: a fence is routinely the
    /// largest thing on a page, so painting it all one literal color makes the loudest region
    /// of the document the one carrying the least meaning. Whatever a fence holds, it is not a
    /// string.
    mutating func scanFence(from content: Int, lineEnd: Int, closerIndent: Int) -> Int? {
        guard let opener = fenceOpener(at: content, upTo: lineEnd) else { return nil }
        let bodyStart = Unit.nextLineStart(after: lineEnd, in: units)
        var cursor = bodyStart
        while cursor < units.count {
            let end = Unit.lineEnd(from: cursor, in: units)
            let lineContent = Unit.firstNonSpace(from: cursor, upTo: end, in: units)
            if closes(
                opener,
                content: lineContent,
                end: end,
                lineStart: cursor,
                closerIndent: closerIndent
            ) {
                emit(content, lineEnd, .keyword)
                emitBody(from: bodyStart, to: cursor, openedAt: content, lineEnd: lineEnd)
                emit(lineContent, end, .keyword)
                return Unit.nextLineStart(after: end, in: units)
            }
            cursor = Unit.nextLineStart(after: end, in: units)
        }
        emit(content, lineEnd, .keyword)
        emitBody(from: bodyStart, to: units.count, openedAt: content, lineEnd: lineEnd)
        return units.count
    }

    /// The block's content, scanned as its own language and re-based onto this document.
    ///
    /// Re-entrant, through a `markdown` fence only, and bounded by a count: a ```` block may hold
    /// a ``` block, so the closing rule no longer bounds the depth by itself, and a file of fences
    /// each one backtick longer than the last would otherwise scan its text once per level.
    /// Past `SyntaxMarkdownScanner.maxNesting`, a Markdown body is left uncolored.
    private mutating func emitBody(from start: Int, to end: Int, openedAt: Int, lineEnd: Int) {
        guard start < end, let language = fenceLanguage(openedAt: openedAt, lineEnd: lineEnd)
        else { return }
        let text = String(decoding: units[start..<end], as: UTF16.self)
        // The slice is cut at line boundaries, so it cannot split a surrogate pair — but a
        // re-encode that changed length would slide every offset below it, and a wrong offset
        // is the one failure that is not merely a wrong color. Checked rather than argued.
        guard text.utf16.count == end - start else { return }
        let body: [SyntaxToken]
        if language == .markdown {
            guard depth < SyntaxMarkdownScanner.maxNesting else { return }
            body = SyntaxMarkdownScanner.tokens(in: text, depth: depth + 1)
        } else {
            body = SyntaxHighlighter.tokens(in: text, language: language)
        }
        for token in body {
            tokens.append(
                SyntaxToken(
                    offset: start + token.offset,
                    length: token.length,
                    kind: token.kind
                )
            )
        }
    }

    /// The language named after the opening fence's run of delimiters, if any.
    private func fenceLanguage(openedAt: Int, lineEnd: Int) -> SyntaxLanguage? {
        var position = openedAt
        while position < lineEnd, units[position] == units[openedAt] { position += 1 }
        guard position < lineEnd else { return nil }
        return SyntaxLanguage.forFenceInfo(
            String(decoding: units[position..<lineEnd], as: UTF16.self)
        )
    }

    /// The fence a line opens, its character and how many of it, when at least three open the
    /// line. A backtick fence's info string may hold no backtick, which is what leaves
    /// ```` ```code``` ```` at the start of a line an inline code span, as CommonMark has it.
    func fenceOpener(at content: Int, upTo end: Int) -> (unit: UInt16, length: Int)? {
        guard content < end else { return nil }
        let unit = units[content]
        guard unit == Unit.backtick || unit == Unit.tilde else { return nil }
        let run = runLength(of: unit, from: content, to: end)
        guard run >= 3 else { return nil }
        if unit == Unit.backtick, units[(content + run)..<end].contains(Unit.backtick) { return nil }
        return (unit, run)
    }

    private func closes(
        _ opener: (unit: UInt16, length: Int),
        content: Int,
        end: Int,
        lineStart: Int,
        closerIndent: Int
    ) -> Bool {
        guard content < end, units[content] == opener.unit else { return false }
        let run = runLength(of: opener.unit, from: content, to: end)
        guard run >= opener.length,
              Unit.firstNonSpace(from: content + run, upTo: end, in: units) == end
        else { return false }
        return column(of: content, from: lineStart) < closerIndent
    }

    /// `#` … `######`, which must be followed by a space or by the end of the line.
    func headingEnd(from content: Int, to end: Int) -> Int? {
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
    func isThematicBreak(from content: Int, to end: Int) -> Bool {
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

    /// `- `, `* `, `+ `, `1. ` or `1) ` — the marker only, never the space after it. A marker
    /// alone on its line is an empty item, which keeps a column of bare `-` lines a list rather
    /// than a setext underline under the one above; `scanBlock` withholds it below a top-level
    /// paragraph, which CommonMark says an empty item cannot interrupt.
    func listMarkerEnd(from content: Int, to end: Int) -> Int? {
        let unit = units[content]
        if unit == Unit.minus || unit == Unit.asterisk || unit == Unit.plus {
            guard content + 1 == end || Unit.isSpaceOrTab(units[content + 1]) else { return nil }
            return content + 1
        }
        guard Unit.isDigit(unit) else { return nil }
        var position = content
        while position < end, Unit.isDigit(units[position]) { position += 1 }
        guard position < end, units[position] == Unit.dot || units[position] == Unit.closeParen
        else { return nil }
        position += 1
        guard position == end || Unit.isSpaceOrTab(units[position]) else { return nil }
        return position
    }

    // MARK: Inline constructs

    /// Code spans, emphasis and links, within one line. Anything whose closer is not on the
    /// same line colors nothing at all — silence beats painting the paragraph.
    mutating func scanInline(from start: Int, to end: Int) {
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

    mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxToken.Kind) {
        let bounded = min(end, units.count)
        guard bounded > start else { return }
        tokens.append(SyntaxToken(offset: start, length: bounded - start, kind: kind))
    }
}
