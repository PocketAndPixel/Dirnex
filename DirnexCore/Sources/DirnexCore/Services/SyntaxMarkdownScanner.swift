import Foundation

/// Markdown (PLAN.md §M17 ▸ Slice 2).
///
/// Line-oriented, which is what makes it cheap: a heading, a blockquote, a list marker and a
/// thematic break are all decided from the first characters of a line, and only the **code fence**
/// spans lines. Inline constructs are then scanned within the line and never across it, so an
/// unclosed `*` costs its own line rather than the rest of the document — the same bound the source
/// scanner puts on an unterminated quote.
///
/// The kinds, and the reasoning for each: a **heading** is `.keyword` and a **thematic break** and
/// a **fence line** are too, because all three are the document's own structure; a **blockquote**
/// is `.comment`, being an aside; an inline **code span** is `.string`, being literal text; a
/// **list marker** is `.number`, which is what an ordered one literally is; and **emphasis** and a
/// **link's text** are `.typeOrTag`, the remaining bucket, with the link's URL taking `.string`
/// beside it. A **fenced block's body** is none of these — it is scanned as the language its info
/// string names, and left alone when it names none; see `scanFence`.
///
/// Two constructs need the line before, which M17 left out for that reason and M39 ▸ Slice 9 took
/// up: the **setext heading**, text underlined with `===` or `---`, and the **indented code
/// block**, four columns in where no paragraph is open. What the scanner keeps between lines is the
/// least that answers both, a few values and no stack: the open paragraph, the latest list item's
/// content column, and the indent a code block's lines must keep. A heading underlined takes
/// `.keyword` on every line, the underline included. An indented block colors nothing, as an
/// undecorated fence does, and is drawn that way by VS Code, whose palette this is; what it fixes
/// is that a `# comment` or a `*ptr` inside one no longer colors as a heading or emphasis. Each rule
/// was scored against micromark over every `.md` file on this Mac (PLAN.md §M39 ▸ Slice 9).
enum SyntaxMarkdownScanner {
    /// How deep a `markdown` fence inside a `markdown` fence is still colored, the document
    /// itself being level zero. A page about Markdown shows a ```` block holding ``` blocks, which
    /// is one level; the bound is there for a file built to go further.
    static let maxNesting = 3

    static func tokens(in text: String, depth: Int = 0) -> [SyntaxToken] {
        guard !text.isEmpty else { return [] }
        var scanner = Scanner(units: Array(text.utf16), depth: depth)
        return scanner.run()
    }

    /// What the line before left open, as `Scanner.paragraph` keeps it.
    private enum Paragraph: Equatable {
        case none
        /// A paragraph at the top level, which an underline makes a heading: where its first
        /// line starts, and how many tokens came before it.
        case open(start: Int, tokenCount: Int)
        /// A paragraph in a list item or a blockquote. It takes lazy lines, but CommonMark lets
        /// no underline below it be one, so a `---` there stays a thematic break.
        case contained

        var isOpen: Bool {
            if case .open = self { return true }
            return false
        }
    }

    /// Internal rather than private so `SyntaxMarkdownScanner+Constructs.swift` can extend it.
    struct Scanner {
        let units: [UInt16]
        /// How many `markdown` fences this text sits inside (`SyntaxMarkdownScanner.maxNesting`).
        let depth: Int
        var tokens: [SyntaxToken] = []
        /// The paragraph the line before belongs to, which is the line of memory a setext heading
        /// needs.
        private var paragraph = Paragraph.none
        /// The content column of the latest list item while a list is open, `nil` outside one.
        ///
        /// One column rather than a stack of them, so after a nested list it holds the innermost
        /// item's column even when a later line has gone back to an outer one. That errs one way
        /// only: a line has to sit further in to be read as code than it needs to, so a code block
        /// may be missed but a list's own paragraph is never painted as one.
        private var listColumn: Int?
        /// While inside an indented code block, the column its lines must reach to stay in it.
        private var codeColumn: Int?
        private var previousLineBlank = true

        init(units: [UInt16], depth: Int) {
            self.units = units
            self.depth = depth
        }

        mutating func run() -> [SyntaxToken] {
            var lineStart = scanFrontMatter()
            while lineStart < units.count { lineStart = scanLine(from: lineStart) }
            return tokens
        }

        /// One line — or, for a fence, one block. Returns where scanning continues.
        private mutating func scanLine(from lineStart: Int) -> Int {
            let end = Unit.lineEnd(from: lineStart, in: units)
            let next = Unit.nextLineStart(after: end, in: units)
            let content = Unit.firstNonSpace(from: lineStart, upTo: end, in: units)
            guard content < end else {
                paragraph = .none
                previousLineBlank = true
                return next
            }
            defer { previousLineBlank = false }
            let indent = column(of: content, from: lineStart)
            if let required = codeColumn {
                if indent >= required { return next }
                codeColumn = nil
            }
            leaveListIfOutside(indent: indent, content: content, end: end)
            // Four columns past the container's content is never a block's start: it opens a code
            // block where no paragraph is open, and continues the paragraph where one is.
            let codeIndent = (listColumn ?? 0) + 4
            if indent >= codeIndent {
                if paragraph == .none {
                    codeColumn = codeIndent
                } else {
                    scanInline(from: content, to: end)
                }
                return next
            }
            if case let .open(start, tokenCount) = paragraph, isUnderline(from: content, to: end) {
                emitHeading(from: start, through: lineStart, after: tokenCount)
                return next
            }
            return scanBlock(lineStart: lineStart, content: content, end: end, next: next)
        }

        /// The constructs a line opens by its first characters, with the paragraph state each
        /// leaves behind.
        private mutating func scanBlock(lineStart: Int, content: Int, end: Int, next: Int) -> Int {
            let closerIndent = (listColumn ?? 0) + 4
            if let afterFence = scanFence(from: content, lineEnd: end, closerIndent: closerIndent) {
                paragraph = .none
                return afterFence
            }
            if headingEnd(from: content, to: end) != nil || isThematicBreak(from: content, to: end) {
                emit(content, end, .keyword)
                paragraph = .none
                return next
            }
            if units[content] == Unit.greater {
                emit(content, end, .comment)
                paragraph = .contained
                return next
            }
            var cursor = content
            if let marker = listMarkerEnd(from: content, to: end),
               !paragraph.isOpen || Unit.firstNonSpace(from: marker, upTo: end, in: units) < end {
                emit(content, marker, .number)
                cursor = marker
                listColumn = contentColumn(after: marker, to: end, from: lineStart)
                paragraph = .contained
            } else if paragraph == .none {
                paragraph = listColumn == nil
                    ? .open(start: lineStart, tokenCount: tokens.count) : .contained
            } else if isTableDelimiterRow(from: content, to: end) {
                // The line above was a table's header, and a table's rows take no underline: a
                // `---` straight under the last row is a thematic break, as GitHub draws it.
                paragraph = .contained
            }
            scanInline(from: cursor, to: end)
            return next
        }

        /// GFM's delimiter row, `| --- | :-: |`: pipes, hyphens, colons and spaces, with at least
        /// one pipe, which is what keeps a lone `---` an underline.
        private func isTableDelimiterRow(from content: Int, to end: Int) -> Bool {
            var sawPipe = false
            var sawHyphen = false
            for position in content..<end {
                switch units[position] {
                case Unit.pipe: sawPipe = true
                case Unit.minus: sawHyphen = true
                case Unit.colon, Unit.space, Unit.tab: break
                default: return false
                }
            }
            return sawPipe && sawHyphen
        }

        // MARK: Setext headings

        /// A run of `=` or of `-` with nothing after it but spaces, CommonMark's underline. One
        /// character is enough, and a space inside the run makes `- - -` a thematic break instead.
        private func isUnderline(from content: Int, to end: Int) -> Bool {
            let marker = units[content]
            guard marker == Unit.equals || marker == Unit.minus else { return false }
            var position = content
            while position < end, units[position] == marker { position += 1 }
            while position < end, Unit.isSpaceOrTab(units[position]) { position += 1 }
            return position == end
        }

        /// The paragraph from `start` and its underline at `underline`, every line `.keyword` in
        /// place of what its inline scan colored. The one place the scanner takes back tokens it
        /// emitted, and only its own paragraph's: a forward look for the underline from each
        /// paragraph's first line would read the same lines twice to the same end.
        private mutating func emitHeading(
            from start: Int,
            through underline: Int,
            after tokenCount: Int
        ) {
            tokens.removeSubrange(tokenCount...)
            var line = start
            while true {
                let end = Unit.lineEnd(from: line, in: units)
                emit(Unit.firstNonSpace(from: line, upTo: end, in: units), end, .keyword)
                guard line < underline else { break }
                line = Unit.nextLineStart(after: end, in: units)
            }
            paragraph = .none
        }

        // MARK: Lists and indentation

        /// Closes the list when a line falls outside the latest item: one less indented that is
        /// neither a new item nor a lazy line of the item's paragraph. A line still two columns in
        /// may belong to an outer item, whose column was not kept, so its own indent stands in.
        private mutating func leaveListIfOutside(indent: Int, content: Int, end: Int) {
            guard let column = listColumn, indent < column,
                  listMarkerEnd(from: content, to: end) == nil
            else { return }
            let opensBlock = fenceOpener(at: content, upTo: end) != nil
                || headingEnd(from: content, to: end) != nil
                || isThematicBreak(from: content, to: end) || units[content] == Unit.greater
            if !previousLineBlank, paragraph != .none, !opensBlock { return }
            listColumn = indent >= 2 ? indent : nil
        }

        /// Where a list item's content starts, which is how far in its own lines must sit. One to
        /// four columns after the marker count; with more, the content is code one column in.
        private func contentColumn(after marker: Int, to end: Int, from lineStart: Int) -> Int {
            let markerEnd = column(of: marker, from: lineStart)
            let text = Unit.firstNonSpace(from: marker, upTo: end, in: units)
            guard text < end else { return markerEnd + 1 }
            let textColumn = column(of: text, from: lineStart)
            return textColumn - markerEnd > 4 ? markerEnd + 1 : textColumn
        }

        /// The column `position` sits at, a tab moving on to the next multiple of four.
        func column(of position: Int, from lineStart: Int) -> Int {
            var column = 0
            for index in lineStart..<position {
                column = units[index] == Unit.tab ? column + 4 - column % 4 : column + 1
            }
            return column
        }

        // MARK: Front matter

        /// YAML front matter, found by `MarkdownFrontMatter`'s own rule so the source and the page
        /// agree on where it ends: `---` on the first line, a `---` or `...` closing it, and a
        /// `key:` as the first line between. Its lines color as they always have; what changes is
        /// that the closing fence is a fence, where the setext rule would read the last key above
        /// it as a heading. Returns where the document after it starts, `0` when there is none.
        private mutating func scanFrontMatter() -> Int {
            guard let closer = frontMatterCloser() else { return 0 }
            var line = 0
            while line < closer {
                let end = Unit.lineEnd(from: line, in: units)
                let next = Unit.nextLineStart(after: end, in: units)
                let content = Unit.firstNonSpace(from: line, upTo: end, in: units)
                line = content < end ? scanBlock(
                    lineStart: line,
                    content: content,
                    end: end,
                    next: next
                ) : next
            }
            paragraph = .none
            listColumn = nil
            // A fence opened inside it ran past the closer, which is the line-by-line answer of
            // before this existed; keep it rather than emit a token behind the ones already out.
            guard line == closer else { return line }
            let end = Unit.lineEnd(from: closer, in: units)
            emit(Unit.firstNonSpace(from: closer, upTo: end, in: units), end, .keyword)
            return Unit.nextLineStart(after: end, in: units)
        }

        /// The start of the closing fence's line, or `nil` when the file opens with no front matter.
        private func frontMatterCloser() -> Int? {
            let firstEnd = Unit.lineEnd(from: 0, in: units)
            guard isFrontMatterFence(from: 0, to: firstEnd, opening: true) else { return nil }
            var line = Unit.nextLineStart(after: firstEnd, in: units)
            var sawKey = false
            while line < units.count {
                let end = Unit.lineEnd(from: line, in: units)
                if isFrontMatterFence(from: line, to: end, opening: false) { return sawKey ? line : nil }
                if !sawKey, Unit.firstNonSpace(from: line, upTo: end, in: units) < end {
                    guard opensWithKey(from: line, to: end) else { return nil }
                    sawKey = true
                }
                line = Unit.nextLineStart(after: end, in: units)
            }
            return nil
        }

        private func isFrontMatterFence(from start: Int, to end: Int, opening: Bool) -> Bool {
            let content = Unit.firstNonSpace(from: start, upTo: end, in: units)
            var trimmed = end
            while trimmed > content, Unit.isSpaceOrTab(units[trimmed - 1]) { trimmed -= 1 }
            guard trimmed - content == 3 else { return false }
            let unit = units[content]
            guard unit == Unit.minus || (!opening && unit == Unit.dot) else { return false }
            return units[content + 1] == unit && units[content + 2] == unit
        }

        /// An unindented `key:` whose key holds no whitespace.
        private func opensWithKey(from start: Int, to end: Int) -> Bool {
            var position = start
            while position < end, units[position] != Unit.colon {
                if Unit.isSpaceOrTab(units[position]) { return false }
                position += 1
            }
            return position > start && position < end
        }
    }
}
