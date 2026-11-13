import Foundation

/// One footnote's definition: the label it was written with and its content.
public struct MarkdownFootnote: Equatable, Sendable {
    /// The label as the definition spells it, which is what its anchor is made from: GitHub keeps
    /// the definition's case (`[^Mixed]` anchors as `fn-Mixed`, whichever case a reference uses).
    public let label: String
    public let blocks: [MarkdownBlock]

    public init(label: String, blocks: [MarkdownBlock]) {
        self.label = label
        self.blocks = blocks
    }
}

/// GFM footnotes, `text[^1]` and `[^1]: the note` (PLAN.md §M39 ▸ Slice 6).
///
/// Every rule here was read off GitHub's own renderer (its `/markdown` API, 2026-11-13), since GFM's
/// spec does not cover footnotes:
///
/// - A label is one or more characters with no whitespace: `[^a b]` and `[^]` stay text.
/// - A definition starts a line, interrupts a paragraph, and may sit inside a quote or a list item.
///   Its first paragraph continues lazily; anything after a blank line belongs to it only when
///   indented four columns. An empty definition is still a footnote.
/// - A reference matches its definition case-insensitively, the first definition wins, a reference
///   with no definition stays text, and a definition nobody references is not drawn.
/// - Footnotes are numbered in the order they are first referenced, and drawn in that order at the
///   foot of the page, each with a way back to every reference to it (`fnref-1`, `fnref-1-2`).
///
/// A footnote's definition is a block of its own here, drawn as nothing where it stands; the
/// renderer draws the list (`MarkdownHTMLRenderer+Footnotes`). One departure: GitHub puts a
/// reference's *number* into the anchor of a heading that holds one (`## Heading[^h]` anchors as
/// `#heading3`). Here the reference adds nothing to the heading's text, since its number is only
/// known once the page before it has been drawn.
enum MarkdownFootnotes {
    /// The label and the rest of the line when `line` opens a footnote definition.
    static func definition(in line: some StringProtocol) -> (label: String, body: String)? {
        guard MarkdownLine.indentation(of: line) < 4 else { return nil }
        let content = MarkdownLine.content(of: line)
        guard content.hasPrefix("[^") else { return nil }
        let rest = content.dropFirst(2)
        guard let close = rest.firstIndex(of: "]") else { return nil }
        let label = rest[rest.startIndex..<close]
        guard isLabel(label) else { return nil }
        let after = rest[rest.index(after: close)...]
        guard after.first == ":" else { return nil }
        return (String(label), String(MarkdownLine.content(of: after.dropFirst())))
    }

    /// Whether `text` can be a footnote's label: not empty, and no whitespace or bracket in it.
    static func isLabel(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && !text.contains { $0.isWhitespace || $0 == "[" || $0 == "]" }
    }

    /// The key of the footnote `[^label]` at `start` names, and the index after its `]`, when the
    /// document defines one. A reference with no definition is text, as on GitHub.
    static func reference(
        in characters: [Character],
        at start: Int,
        footnotes: Set<String>
    ) -> (key: String, end: Int)? {
        guard !footnotes.isEmpty, start + 1 < characters.count, characters[start + 1] == "^",
              let close = characters[(start + 2)...].firstIndex(of: "]")
        else { return nil }
        let label = String(characters[(start + 2)..<close])
        guard isLabel(label) else { return nil }
        let key = MarkdownLinkReference.key(for: label)
        return footnotes.contains(key) ? (key, close + 1) : nil
    }

    /// Take the definition starting at `start`, and answer the line after it.
    static func take(from lines: [String], at start: Int) -> (MarkdownBlock, Int)? {
        guard let (label, body) = definition(in: lines[start]) else { return nil }
        var content = [body]
        var index = start + 1
        var blanks = 0
        while index < lines.count {
            let line = lines[index]
            if MarkdownLine.isBlank(line) {
                blanks += 1
                index += 1
                continue
            }
            if MarkdownLine.indentation(of: line) >= 4 {
                content.append(contentsOf: Array(repeating: "", count: blanks))
                blanks = 0
                content.append(MarkdownLine.removingIndent(4, from: line))
                index += 1
                continue
            }
            // Lazy continuation of the paragraph the definition opened, while nothing has ended it.
            // A definition with nothing on its own line has no paragraph to continue.
            if blanks == 0, let last = content.last, !MarkdownLine.isBlank(last),
               !MarkdownBlockParser.startsBlock(lines, at: index) {
                content.append(line)
                index += 1
                continue
            }
            break
        }
        let blocks = MarkdownBlockParser.blocks(in: content)
        return (.footnoteDefinition(label: label, blocks: blocks), index)
    }

    /// Every definition in the document, keyed as references look them up, the first one winning.
    static func gather(from blocks: [MarkdownBlock]) -> [String: MarkdownFootnote] {
        var footnotes: [String: MarkdownFootnote] = [:]
        collect(blocks, into: &footnotes)
        return footnotes
    }

    private static func collect(
        _ blocks: [MarkdownBlock],
        into footnotes: inout [String: MarkdownFootnote]
    ) {
        for block in blocks {
            switch block {
            case let .footnoteDefinition(label, inner):
                let key = MarkdownLinkReference.key(for: label)
                if footnotes[key] == nil {
                    footnotes[key] = MarkdownFootnote(label: label, blocks: inner)
                }
                collect(inner, into: &footnotes)
            case let .blockQuote(inner), let .alert(_, inner):
                collect(inner, into: &footnotes)
            case let .list(list):
                for item in list.items {
                    collect(item.blocks, into: &footnotes)
                }
            case let .definitionList(items):
                for definition in items.flatMap(\.definitions) {
                    collect(definition.blocks, into: &footnotes)
                }
            case .heading, .paragraph, .thematicBreak, .codeBlock, .table, .frontMatter,
                 .tableOfContents:
                break
            }
        }
    }

    /// The label as it goes into an anchor: percent-encoded past the characters a fragment may hold
    /// as they are, which is how GitHub writes it (`[^é]` anchors as `fn-%C3%A9`). Every anchor is
    /// then ASCII, so a link to it reaches it whatever the label was.
    static func anchor(for label: String) -> String {
        label.addingPercentEncoding(withAllowedCharacters: anchorCharacters) ?? label
    }

    private static let anchorCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'()*+,;=:@/?"
    )
}
