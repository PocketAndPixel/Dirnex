import Foundation

/// The inline pass: the text inside one block, as `MarkdownInline` nodes (PLAN.md §M18 ▸ Slice 1).
///
/// Two stages, and the split is what makes emphasis come out right. The **scan** below walks the
/// text once and produces a flat list of finished nodes with the `*`, `_` and `~` runs left in it as
/// *delimiters*; `MarkdownInlineEmphasis` then pairs those from the inside out. Trying to match a
/// closer while scanning forward is the version that looks simpler and gets `*a **b** c*` wrong —
/// the `**` after `b` is a legal closer for the outer `*`, so a greedy scan ends the emphasis in the
/// middle of the strong one.
///
/// Everything here works in `Character`s rather than UTF-16 units, unlike `SyntaxHighlighter` next
/// door: that scanner hands back *offsets* into the app's string and has to speak `NSRange`'s unit,
/// while this produces text. Grapheme clusters are also the unit the flanking rules want — "is the
/// character before this `*` whitespace" is a question about what the reader sees.
enum MarkdownInlineParser {
    static func parse(
        _ source: String,
        references: [String: MarkdownLinkReference] = [:]
    ) -> [MarkdownInline] {
        guard !source.isEmpty else { return [] }
        var scanner = Scanner(characters: Array(source), references: references)
        return MarkdownInlineEmphasis.resolve(scanner.run())
    }

    /// The literal text of `source` — every construct flattened away, which is what an image's
    /// `alt` and a heading's anchor need.
    static func plainText(_ nodes: [MarkdownInline]) -> String {
        nodes.map { node in
            switch node {
            case let .text(text): text
            case let .code(code): code
            case let .emphasis(children), let .strong(children), let .strikethrough(children):
                plainText(children)
            case let .link(_, _, children): plainText(children)
            case let .image(_, _, alt): alt
            case .lineBreak, .softBreak: " "
            }
        }.joined()
    }

    struct Scanner {
        let characters: [Character]
        let references: [String: MarkdownLinkReference]
        private var items: [MarkdownInlineEmphasis.Item] = []
        private var pending = ""
        private var index = 0

        init(characters: [Character], references: [String: MarkdownLinkReference]) {
            self.characters = characters
            self.references = references
        }

        mutating func run() -> [MarkdownInlineEmphasis.Item] {
            while index < characters.count {
                let character = characters[index]
                switch character {
                case "\\": takeEscape()
                case "`": takeCodeSpan()
                case "<": takeAngle()
                case "!": takeImageOrText()
                case "[": takeLink()
                case "&": takeEntity()
                case "\n": takeNewline()
                case "*", "_", "~": takeDelimiterRun(character)
                default:
                    pending.append(character)
                    index += 1
                }
            }
            flushPending()
            return items
        }

        // MARK: Leaf constructs

        /// A backslash escapes ASCII punctuation and nothing else — `\n` in a Markdown file is the
        /// two characters, not a newline, and treating it otherwise would rewrite every Windows
        /// path in a document.
        private mutating func takeEscape() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let next, next == "\n" {
                flushPending()
                items.append(.node(.lineBreak))
                index += 2
                return
            }
            if let next, next.isASCII, next.isPunctuation || next.isSymbol {
                pending.append(next)
                index += 2
                return
            }
            pending.append("\\")
            index += 1
        }

        /// A code span closes on a backtick run of the **same** length, which is what lets
        /// `` `a `b` c` `` hold a backtick. An unclosed run is literal text.
        private mutating func takeCodeSpan() {
            let opening = runLength(of: "`", from: index)
            var cursor = index + opening
            while cursor < characters.count {
                guard characters[cursor] == "`" else {
                    cursor += 1
                    continue
                }
                let closing = runLength(of: "`", from: cursor)
                guard closing == opening else {
                    cursor += closing
                    continue
                }
                flushPending()
                items.append(.node(.code(codeSpanText(from: index + opening, to: cursor))))
                index = cursor + closing
                return
            }
            pending.append(String(repeating: "`", count: opening))
            index += opening
        }

        /// A code span's content: newlines become spaces, and one space is stripped from each end
        /// when both are present — the rule that lets `` ` `` be written as `` `` ` `` ``.
        private func codeSpanText(from start: Int, to end: Int) -> String {
            var text = String(characters[start..<end]).replacingOccurrences(of: "\n", with: " ")
            if text.count > 2, text.hasPrefix(" "), text.hasSuffix(" "),
               text.contains(where: { $0 != " " }) {
                text = String(text.dropFirst().dropLast())
            }
            return text
        }

        /// `<https://…>` and `<name@example.com>`. Anything else beginning with `<` is literal —
        /// raw HTML is text in this renderer, by design (PLAN.md §M18), so the tag a page tried to
        /// smuggle in renders as the characters it is made of.
        private mutating func takeAngle() {
            // Bounded at the line, so an unmatched `<` costs its own line rather than scanning the
            // whole paragraph for a `>` that belongs to something else entirely.
            let limit = characters[index...].firstIndex(of: "\n") ?? characters.count
            guard let close = characters[index..<limit].firstIndex(of: ">"),
                  let link = MarkdownAutolink.parse(String(characters[(index + 1)..<close]))
            else {
                pending.append("<")
                index += 1
                return
            }
            flushPending()
            items.append(.node(.link(
                destination: link.destination,
                title: nil,
                children: [.text(link.label)]
            )))
            index = close + 1
        }

        private mutating func takeImageOrText() {
            guard index + 1 < characters.count, characters[index + 1] == "[" else {
                pending.append("!")
                index += 1
                return
            }
            takeBracketed(isImage: true)
        }

        private mutating func takeLink() {
            takeBracketed(isImage: false)
        }

        private mutating func takeEntity() {
            guard let (character, length) = MarkdownEntity.decode(characters, at: index) else {
                pending.append("&")
                index += 1
                return
            }
            pending.append(character)
            index += length
        }

        /// A newline is a soft break — unless the line it ends asked to be kept, with two or more
        /// trailing spaces. (The backslash form is handled in `takeEscape`.)
        private mutating func takeNewline() {
            var spaces = 0
            while pending.hasSuffix(" ") {
                pending.removeLast()
                spaces += 1
            }
            flushPending()
            items.append(.node(spaces >= 2 ? .lineBreak : .softBreak))
            index += 1
        }

        // MARK: Links and images

        /// `[text](url "title")`, `[text][label]`, `[label][]` and `[label]`, with the image form of
        /// each. A bracket that resolves to none of them is literal, and its contents are still
        /// parsed — `[see note]` in prose keeps its brackets and its emphasis both.
        private mutating func takeBracketed(isImage: Bool) {
            let open = isImage ? index + 1 : index
            guard let close = matchingBracket(from: open) else {
                pending.append(isImage ? "!" : "[")
                index += 1
                return
            }
            let label = String(characters[(open + 1)..<close])
            guard let target = MarkdownLinkTarget.take(
                characters,
                after: close,
                label: label,
                references: references
            ) else {
                pending.append(isImage ? "![" : "[")
                index = open + 1
                return
            }
            flushPending()
            items.append(.node(node(
                isImage: isImage,
                label: label,
                destination: target.destination,
                title: target.title
            )))
            index = target.end
        }

        private func node(
            isImage: Bool,
            label: String,
            destination: String,
            title: String?
        ) -> MarkdownInline {
            let children = MarkdownInlineParser.parse(label, references: references)
            guard isImage else {
                return .link(destination: destination, title: title, children: children)
            }
            return .image(
                source: destination,
                title: title,
                alt: MarkdownInlineParser.plainText(children)
            )
        }

        /// The `]` closing the `[` at `start`, counting nested brackets and skipping escapes so a
        /// link whose text contains `[1]` still closes in the right place.
        private func matchingBracket(from start: Int) -> Int? {
            var depth = 0
            var cursor = start
            while cursor < characters.count {
                switch characters[cursor] {
                case "\\": cursor += 1
                case "[": depth += 1
                case "]":
                    depth -= 1
                    if depth == 0 { return cursor }
                default: break
                }
                cursor += 1
            }
            return nil
        }

        // MARK: Emphasis delimiters

        /// Emit a run of `*`, `_` or `~` as a delimiter for the second pass, with the two flanking
        /// facts it needs: whether it can open, and whether it can close.
        ///
        /// The `_` rules differ from `*`'s, and the asymmetry is CommonMark's for a good reason —
        /// `report_2026_final.pdf` and `my_variable_name` are text people write, so an intraword
        /// `_` opens nothing. `*` has no such carve-out because `a*b*c` is emphasis to every reader.
        private mutating func takeDelimiterRun(_ marker: Character) {
            let length = runLength(of: marker, from: index)
            let before = index > 0 ? characters[index - 1] : nil
            let after = index + length < characters.count ? characters[index + length] : nil
            let openable = after.map { !$0.isWhitespace } ?? false
            let closable = before.map { !$0.isWhitespace } ?? false
            let intraword = (before?.isLetter ?? false) || (before?.isNumber ?? false)
            flushPending()
            items.append(.delimiter(MarkdownInlineEmphasis.Delimiter(
                marker: marker,
                length: length,
                canOpen: openable && (marker != "_" || !intraword),
                canClose: closable && (marker != "_" || !(after?.isLetter ?? false))
            )))
            index += length
        }

        // MARK: Primitives

        private func runLength(of character: Character, from start: Int) -> Int {
            var length = 0
            while start + length < characters.count, characters[start + length] == character {
                length += 1
            }
            return length
        }

        private mutating func flushPending() {
            guard !pending.isEmpty else { return }
            items.append(.node(.text(pending)))
            pending = ""
        }
    }
}
