import Foundation

/// A parsed document: its blocks, and the link definitions they resolve against.
public struct MarkdownBlockScan: Equatable, Sendable {
    public let blocks: [MarkdownBlock]
    /// Keyed by `MarkdownLinkReference.key(for:)`, so a use and its definition match with the case
    /// and the internal spacing they were written with.
    public let references: [String: MarkdownLinkReference]
    /// Every heading in the document, in the order it is rendered in, each with the anchor it will
    /// carry. Both the `id`s and `[[_TOC_]]`'s links come from this one list (PLAN.md §M18 ▸
    /// Slice 2) — see `MarkdownHeadings` for why it is not derived twice.
    public let headings: [MarkdownHeading]

    public init(
        blocks: [MarkdownBlock],
        references: [String: MarkdownLinkReference] = [:],
        headings: [MarkdownHeading] = []
    ) {
        self.blocks = blocks
        self.references = references
        self.headings = headings
    }
}

/// The block pass: Markdown source in, `MarkdownBlock`s out (PLAN.md §M18 ▸ Slice 1).
///
/// Line-oriented and single-pass, with two sweeps ahead of it that both exist for the same reason —
/// they read something a linear walk cannot use in the order it arrives. **Front matter** is only
/// front matter at the very top of the file, and **link reference definitions** are routinely
/// written hundreds of lines *after* the links that use them.
///
/// The order the constructs are tested in is load-bearing in three places, each of which is a real
/// document that would otherwise render wrong: an indented line is code before it is anything else;
/// a thematic break is tested before a list marker, or `---` reads as a bullet with no content (the
/// same ordering `SyntaxMarkdownScanner` needs); and a setext underline is tested while *gathering a
/// paragraph*, because `---` under a line of text is a heading and `---` on its own is a rule.
enum MarkdownBlockParser {
    /// Parse a whole document.
    static func scan(_ text: String) -> MarkdownBlockScan {
        var lines = MarkdownLine.split(text)
        var blocks: [MarkdownBlock] = []
        if let matter = MarkdownFrontMatter.take(from: &lines) {
            blocks.append(.frontMatter(matter))
        }
        let references = MarkdownLinkDefinitions.extract(from: &lines)
        blocks.append(contentsOf: self.blocks(in: lines))
        return MarkdownBlockScan(
            blocks: blocks,
            references: references,
            headings: MarkdownHeadings.gather(from: blocks, references: references)
        )
    }

    /// Parse a run of lines that has already had its container's marker stripped — a blockquote's
    /// contents, or a list item's. The recursion that makes a list nest and a quote hold a table.
    static func blocks(in lines: [String]) -> [MarkdownBlock] {
        var parser = Parser(lines: lines)
        return parser.run()
    }

    // MARK: - Line predicates
    //
    // Static and shared rather than private to `Parser`, because `MarkdownListParser` asks the same
    // question when it decides whether an unindented line continues an item's paragraph or starts
    // something new. One definition of "this line opens a block" — two would drift, and the drift
    // would show up as a heading swallowed into the bullet above it.

    /// `#` … `######` followed by a space or the end of the line, with an optional closing run of
    /// hashes that is *not* part of the text.
    static func atxHeading(_ content: some StringProtocol) -> MarkdownBlock? {
        var level = 0
        var index = content.startIndex
        while index < content.endIndex, content[index] == "#", level < 7 {
            level += 1
            index = content.index(after: index)
        }
        guard (1...6).contains(level) else { return nil }
        guard index == content.endIndex || content[index] == " " || content[index] == "\t"
        else { return nil }
        let text = trimmingClosingHashes(content[index...])
        return .heading(level: level, text: String(MarkdownLine.content(of: text)))
    }

    /// A trailing `###` run is decoration and comes off — but only when a space separates it from
    /// the text, or `# C#` would lose the language it names.
    private static func trimmingClosingHashes(_ text: some StringProtocol) -> String {
        let trimmed = MarkdownLine.trimmingTrailingWhitespace(text)
        guard let lastKept = trimmed.lastIndex(where: { $0 != "#" }) else {
            return trimmed.isEmpty ? trimmed : ""
        }
        guard trimmed[lastKept] == " " || trimmed[lastKept] == "\t" else { return trimmed }
        return MarkdownLine.trimmingTrailingWhitespace(trimmed[..<lastKept])
    }

    /// Three or more `-`, `*` or `_`, alone on the line but for spaces.
    static func isThematicBreak(_ content: some StringProtocol) -> Bool {
        guard let marker = content.first, "-*_".contains(marker) else { return false }
        var count = 0
        for character in content {
            if character == marker {
                count += 1
            } else if !character.isWhitespace {
                return false
            }
        }
        return count >= 3
    }

    /// `===` or `---` alone under a paragraph: heading level 1 and 2 respectively.
    static func setextLevel(_ line: some StringProtocol) -> Int? {
        guard MarkdownLine.indentation(of: line) < 4 else { return nil }
        let content = MarkdownLine.trimmingTrailingWhitespace(MarkdownLine.content(of: line))
        guard let marker = content.first, marker == "=" || marker == "-" else { return nil }
        guard content.allSatisfy({ $0 == marker }) else { return nil }
        return marker == "=" ? 1 : 2
    }

    /// `[[_TOC_]]` — Azure DevOps' spelling, which is the one people write — or `[TOC]`, alone on
    /// its line.
    ///
    /// Matched case-insensitively because both are written both ways, and required to be the
    /// *whole* line: `[TOC]` is also a legal shortcut reference link, and one sitting inside a
    /// sentence is a link somebody wrote, not a request for an outline.
    static func isTableOfContents(_ content: some StringProtocol) -> Bool {
        let trimmed = MarkdownLine.trimmingTrailingWhitespace(content).uppercased()
        return trimmed == "[[_TOC_]]" || trimmed == "[TOC]"
    }

    /// The fence character and its run length when `content` opens or closes a fenced code block.
    static func fenceRun(_ content: some StringProtocol) -> (marker: Character, length: Int)? {
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        let length = content.prefix { $0 == marker }.count
        return length >= 3 ? (marker, length) : nil
    }

    /// Whether the line at `index` opens a block, and therefore interrupts a paragraph or an item.
    ///
    /// An **indented code block is deliberately absent**: four spaces under a paragraph is a wrapped
    /// line somebody indented, not code, and reading it as code is how a hanging indent turns half a
    /// sentence into a grey box.
    static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        guard MarkdownLine.indentation(of: line) < 4 else { return false }
        let content = MarkdownLine.content(of: line)
        if content.first == ">" { return true }
        if atxHeading(content) != nil { return true }
        if isThematicBreak(content) { return true }
        if fenceRun(content) != nil { return true }
        if isTableOfContents(content) { return true }
        if MarkdownTableParser.take(from: lines, at: index) != nil { return true }
        return MarkdownListParser.interruptsParagraph(lines, at: index)
    }

    // MARK: - The pass itself

    private struct Parser {
        let lines: [String]
        var index = 0
        var blocks: [MarkdownBlock] = []

        mutating func run() -> [MarkdownBlock] {
            while index < lines.count {
                if MarkdownLine.isBlank(lines[index]) {
                    index += 1
                    continue
                }
                takeBlock()
            }
            return blocks
        }

        private mutating func takeBlock() {
            let line = lines[index]
            let indent = MarkdownLine.indentation(of: line)
            guard indent < 4 else {
                takeIndentedCode()
                return
            }
            let content = MarkdownLine.content(of: line)
            if takeFencedCode(indent: indent, content: content) { return }
            if let heading = MarkdownBlockParser.atxHeading(content) {
                blocks.append(heading)
                index += 1
                return
            }
            if MarkdownBlockParser.isThematicBreak(content) {
                blocks.append(.thematicBreak)
                index += 1
                return
            }
            if MarkdownBlockParser.isTableOfContents(content) {
                blocks.append(.tableOfContents)
                index += 1
                return
            }
            if content.first == ">" {
                takeBlockQuote()
                return
            }
            if let (table, next) = MarkdownTableParser.take(from: lines, at: index) {
                blocks.append(.table(table))
                index = next
                return
            }
            if let (list, next) = MarkdownListParser.take(from: lines, at: index) {
                blocks.append(.list(list))
                index = next
                return
            }
            takeParagraph()
        }

        /// A fence opens on three or more backticks or tildes and closes on a run of the **same**
        /// character that is at least as long — which is what lets a ``` block quote a `~~~` one.
        ///
        /// An unclosed fence runs to the end of the buffer rather than being rejected. That is what
        /// a truncated read hands over (`TextPreview` cuts at 4 MB), and showing the rest of the
        /// file as code beats showing the fence markers as prose.
        private mutating func takeFencedCode(indent: Int, content: Substring) -> Bool {
            guard let fence = MarkdownBlockParser.fenceRun(content) else { return false }
            let info = MarkdownLine.trimmingTrailingWhitespace(content.dropFirst(fence.length))
                .trimmingCharacters(in: .whitespaces)
            // A backtick in the info string would let a code span's contents open a fence.
            guard fence.marker != "`" || !info.contains("`") else { return false }
            var body: [String] = []
            index += 1
            while index < lines.count {
                if isClosingFence(lines[index], fence) {
                    index += 1
                    break
                }
                body.append(MarkdownLine.removingIndent(indent, from: lines[index]))
                index += 1
            }
            blocks.append(.codeBlock(info: info.isEmpty ? nil : info, code: joined(body)))
            return true
        }

        private func isClosingFence(_ line: String, _ fence: (marker: Character, length: Int)) -> Bool {
            guard MarkdownLine.indentation(of: line) < 4 else { return false }
            let content = MarkdownLine.content(of: line)
            guard let closing = MarkdownBlockParser.fenceRun(content),
                  closing.marker == fence.marker,
                  closing.length >= fence.length
            else { return false }
            return MarkdownLine.isBlank(content.dropFirst(closing.length))
        }

        /// Four columns of indentation or more, blank lines included but never trailing: a code
        /// block ends at its last line of code, not at the blank line before the next paragraph.
        private mutating func takeIndentedCode() {
            var body: [String] = []
            var pending: [String] = []
            while index < lines.count {
                let line = lines[index]
                if MarkdownLine.isBlank(line) {
                    pending.append("")
                    index += 1
                    continue
                }
                guard MarkdownLine.indentation(of: line) >= 4 else { break }
                body.append(contentsOf: pending)
                pending = []
                body.append(MarkdownLine.removingIndent(4, from: line))
                index += 1
            }
            blocks.append(.codeBlock(info: nil, code: joined(body)))
        }

        /// A quote takes every following line carrying `>`, plus **lazy continuation** lines — an
        /// unmarked line that simply continues the paragraph inside it, which is how quoted prose is
        /// written when it wraps.
        private mutating func takeBlockQuote() {
            var inner: [String] = []
            while index < lines.count {
                let line = lines[index]
                let content = MarkdownLine.content(of: line)
                if MarkdownLine.indentation(of: line) < 4, content.first == ">" {
                    var rest = content.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    inner.append(String(rest))
                    index += 1
                    continue
                }
                guard !MarkdownLine.isBlank(line),
                      !MarkdownBlockParser.startsBlock(lines, at: index)
                else { break }
                inner.append(line)
                index += 1
            }
            blocks.append(.blockQuote(MarkdownBlockParser.blocks(in: inner)))
        }

        /// Text up to a blank line or the start of another block — with the **setext** check first,
        /// since `===` or `---` under the text turns everything gathered so far into a heading.
        private mutating func takeParagraph() {
            var gathered: [String] = []
            while index < lines.count {
                let line = lines[index]
                if MarkdownLine.isBlank(line) { break }
                if !gathered.isEmpty, let level = MarkdownBlockParser.setextLevel(line) {
                    index += 1
                    emit(gathered, asHeadingLevel: level)
                    return
                }
                if !gathered.isEmpty, MarkdownBlockParser.startsBlock(lines, at: index) { break }
                gathered.append(String(MarkdownLine.content(of: line)))
                index += 1
            }
            emit(gathered, asHeadingLevel: nil)
        }

        private mutating func emit(_ gathered: [String], asHeadingLevel level: Int?) {
            let text = gathered.joined(separator: "\n")
            guard !text.isEmpty else { return }
            blocks.append(level.map { .heading(level: $0, text: text) } ?? .paragraph(text))
        }

        /// A code block's lines, with a trailing newline when there are any — the shape a `<pre>`
        /// wants, and the one a round-trip test compares against the source.
        private func joined(_ body: [String]) -> String {
            body.isEmpty ? "" : body.joined(separator: "\n") + "\n"
        }
    }
}
