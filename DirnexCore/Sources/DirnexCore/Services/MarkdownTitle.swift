import Foundation

/// A Markdown document's own title (PLAN.md §M39 ▸ Slice 11): its front matter's `title`, or the
/// words of its first heading when that is level 1.
///
/// ## Which heading
///
/// Read off the corpus, 5 655 distinct `.md` files on this Mac (2026-11-14). 4 302 open on a
/// level-1 heading, and only 18 have one later after some other first heading: changelogs whose
/// later `#` is a release (`# [3.4.0](…)`), which is no title. So the first heading counts only
/// when it is level 1, as pandoc reads a document that begins with one. 467 carry a front-matter
/// `title`, some of them `''`, which names none.
///
/// ## Which words
///
/// The heading as the page draws it, less what the page cannot draw as words. The same corpus put
/// a badge or a logo in 500 of 3 651 first headings in the dependencies on this Mac (`# caniuse-api
/// [![Build Status](…)](…)`) and a raw tag in 247 (`<img … align="right">`, `<sup>`, `<br/>`), 1 of
/// 511 each in Oleg's own files. So an image adds nothing, since its alt names the picture and
/// not the document, and neither does a run CommonMark would read as an HTML tag, which GitHub
/// draws as nothing and this renderer draws as the text it was typed as. A code span and a formula
/// keep every character, a tag-shaped one included, and shortcodes are drawn run by run as the
/// heading draws them (`MarkdownEmoji`).
enum MarkdownTitle {
    static func of(_ scan: MarkdownBlockScan) -> String? {
        if case let .frontMatter(entries)? = scan.blocks.first,
           let entry = entries.first(where: { $0.key.lowercased() == "title" }),
           let title = nonEmpty(entry.value),
           !isBlockScalarIndicator(title) {
            return title
        }
        guard let first = MarkdownHeadings.first(in: scan.blocks), first.level == 1 else {
            return nil
        }
        return nonEmpty(words(of: MarkdownInlineParser.parse(
            first.source,
            references: scan.references,
            footnotes: Set(scan.footnotes.keys)
        )))
    }

    /// `text` with each run of whitespace made one space and none at either end.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func nonEmpty(_ text: String) -> String? {
        let title = collapsed(text)
        return title.isEmpty ? nil : title
    }

    /// `|`, `>`, `>-` and the like: YAML's text follows on the lines below, which front matter
    /// reads as rows of their own (`MarkdownFrontMatter`), so the key holds no title.
    private static func isBlockScalarIndicator(_ value: String) -> Bool {
        guard let first = value.first, first == "|" || first == ">" else { return false }
        return value.dropFirst().allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
    }

    // MARK: - The words of a heading

    /// A stretch of a heading's words, and whether it is literal: a code span or a formula, which
    /// no tag is read in.
    private struct Segment {
        let text: String
        let isLiteral: Bool
    }

    /// `nodes` as words, with images and tags left out.
    ///
    /// Tags are looked for across every stretch between two literal ones rather than inside each
    /// run, so `<a title="*x*">`, whose `*x*` is emphasis, is still one tag.
    static func words(of nodes: [MarkdownInline]) -> String {
        var words = ""
        var prose = ""
        for segment in segments(of: nodes) {
            if segment.isLiteral {
                words += withoutTags(prose) + segment.text
                prose = ""
            } else {
                prose += segment.text
            }
        }
        return words + withoutTags(prose)
    }

    /// The renderer's runs (`MarkdownHTMLRenderer+Inline`): the text and soft breaks between two
    /// elements, each with its shortcodes drawn, in a container's children as on the page.
    private static func segments(of nodes: [MarkdownInline]) -> [Segment] {
        var found: [Segment] = []
        var run = ""
        func endRun() {
            guard !run.isEmpty else { return }
            found.append(Segment(text: MarkdownEmoji.converting(run), isLiteral: false))
            run = ""
        }
        for node in nodes {
            switch node {
            case let .text(text):
                run += text
            case .softBreak:
                run += "\n"
            case .lineBreak:
                endRun()
                found.append(Segment(text: " ", isLiteral: false))
            case let .code(code):
                endRun()
                found.append(Segment(text: code, isLiteral: true))
            case let .math(tex, _, _):
                endRun()
                found.append(Segment(text: tex, isLiteral: true))
            case let .emphasis(children), let .strong(children), let .strikethrough(children),
                 let .link(_, _, children):
                endRun()
                found += segments(of: children)
            // A picture is no word, and a footnote's number is the page's to hand out.
            case .image, .footnoteReference:
                endRun()
            }
        }
        endRun()
        return found
    }

    // MARK: - Tags

    /// `text` without the runs CommonMark would read as an open tag, a closing tag or a comment
    /// (§6.6 Raw HTML). Anything else with a `<` in it stays: `a < b`, `1 <2`, `<>`.
    static func withoutTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            if characters[index] == "<", let length = tagLength(in: characters, at: index) {
                index += length
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return output
    }

    /// How many characters the tag opening at `start` takes, or `nil` when none opens there.
    private static func tagLength(in characters: [Character], at start: Int) -> Int? {
        var tag = TagScanner(characters: characters, index: start + 1)
        let length = tag.comment() ?? tag.closingTag() ?? tag.openTag()
        return length.map { $0 - start }
    }

    /// One attempt at a tag, CommonMark's grammar read left to right. Each reading answers the
    /// index just past the tag, or `nil`, and starts again from just after the `<`.
    private struct TagScanner {
        let characters: [Character]
        let start: Int
        var index: Int

        init(characters: [Character], index: Int) {
            self.characters = characters
            start = index
            self.index = index
        }

        private var current: Character? {
            index < characters.count ? characters[index] : nil
        }

        /// `<!-- … -->`.
        mutating func comment() -> Int? {
            index = start
            guard take("!"), take("-"), take("-") else { return nil }
            var end = index
            while end + 2 < characters.count {
                if characters[end] == "-", characters[end + 1] == "-", characters[end + 2] == ">" {
                    return end + 3
                }
                end += 1
            }
            return nil
        }

        /// `</name>`, with whitespace allowed before the `>`.
        mutating func closingTag() -> Int? {
            index = start
            guard take("/"), name() else { return nil }
            _ = whitespace()
            return take(">") ? index : nil
        }

        /// `<name attribute="value" …>` or `<name … />`.
        mutating func openTag() -> Int? {
            index = start
            guard name() else { return nil }
            while true {
                let spaced = whitespace()
                if take(">") { return index }
                if take("/") { return take(">") ? index : nil }
                guard spaced, attribute() else { return nil }
            }
        }

        /// A tag name: an ASCII letter, then ASCII letters, digits and `-`.
        private mutating func name() -> Bool {
            guard let first = current, first.isASCII, first.isLetter else { return false }
            index += 1
            while let next = current, next.isASCII, next.isLetter || next.isNumber || next == "-" {
                index += 1
            }
            return true
        }

        /// An attribute name, and its value when an `=` follows.
        private mutating func attribute() -> Bool {
            guard let first = current, first.isASCII,
                  first.isLetter || first == "_" || first == ":"
            else { return false }
            index += 1
            while let next = current, next.isASCII,
                  next.isLetter || next.isNumber || "_.:-".contains(next) {
                index += 1
            }
            let beforeValue = index
            _ = whitespace()
            guard take("=") else {
                index = beforeValue
                return true
            }
            _ = whitespace()
            return value()
        }

        /// A value in double quotes, single quotes, or none: then at least one character that is
        /// not whitespace, a quote, `=`, `<`, `>` or a backtick.
        private mutating func value() -> Bool {
            if let quote = current, quote == "\"" || quote == "'" {
                index += 1
                while let next = current, next != quote {
                    index += 1
                }
                return take(quote)
            }
            let first = index
            while let next = current, !isWhitespace(next), !"\"'=<>`".contains(next) {
                index += 1
            }
            return index > first
        }

        /// Spaces, tabs and line endings. Answers whether there was any.
        private mutating func whitespace() -> Bool {
            let first = index
            while let next = current, isWhitespace(next) {
                index += 1
            }
            return index > first
        }

        private func isWhitespace(_ character: Character) -> Bool {
            character == " " || character == "\t" || character.isNewline
        }

        private mutating func take(_ character: Character) -> Bool {
            guard current == character else { return false }
            index += 1
            return true
        }
    }
}
