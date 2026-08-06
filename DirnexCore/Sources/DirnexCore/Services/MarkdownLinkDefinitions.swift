import Foundation

/// The sweep that collects `[label]: destination "title"` definitions (PLAN.md §M18 ▸ Slice 1).
///
/// A sweep rather than a case in the block parser, because a definition is routinely written
/// *after* every link that uses it — the whole point of the reference form is that the URLs sit
/// together at the foot of the file. A linear pass would have to hold every unresolved link open
/// until the end; collecting first makes the inline pass a pure lookup.
///
/// Definitions are blanked in place rather than removed, so no line moves: a parser that renumbered
/// lines here would have to renumber every offset the rest of the milestone measures against them.
enum MarkdownLinkDefinitions {
    static func extract(from lines: inout [String]) -> [String: MarkdownLinkReference] {
        var references: [String: MarkdownLinkReference] = [:]
        var fence: Character?
        var openedAtBlockStart = true
        for index in lines.indices {
            let line = lines[index]
            if let marker = fenceMarker(line) {
                fence = fence == marker ? nil : (fence ?? marker)
                openedAtBlockStart = false
                continue
            }
            if MarkdownLine.isBlank(line) {
                openedAtBlockStart = true
                continue
            }
            guard fence == nil, openedAtBlockStart else {
                openedAtBlockStart = false
                continue
            }
            // Only at the head of a block: a `[x]: y` line in the *middle* of a paragraph is prose
            // that happens to look like a definition, and blanking it would split the paragraph in
            // two around a gap with nothing in it.
            guard let (label, reference) = definition(in: line) else {
                openedAtBlockStart = false
                continue
            }
            // First definition wins, which is CommonMark's rule and the forgiving one: a label
            // redefined later in a long document keeps meaning what its first use meant.
            let key = MarkdownLinkReference.key(for: label)
            if references[key] == nil { references[key] = reference }
            lines[index] = ""
        }
        return references
    }

    /// The fence character when a line opens or closes a fenced code block, so a definition-shaped
    /// line *inside* a code sample is left alone.
    private static func fenceMarker(_ line: String) -> Character? {
        guard MarkdownLine.indentation(of: line) < 4 else { return nil }
        let content = MarkdownLine.content(of: line)
        guard let marker = content.first, marker == "`" || marker == "~" else { return nil }
        return content.prefix { $0 == marker }.count >= 3 ? marker : nil
    }

    /// `[label]: destination` with an optional `"title"`, and nothing else on the line.
    static func definition(in line: String) -> (label: String, reference: MarkdownLinkReference)? {
        guard MarkdownLine.indentation(of: line) < 4 else { return nil }
        var rest = MarkdownLine.content(of: line)
        guard rest.first == "[" else { return nil }
        rest = rest.dropFirst()
        guard let close = unescapedIndex(of: "]", in: rest) else { return nil }
        let label = String(rest[rest.startIndex..<close])
        guard !label.isEmpty else { return nil }
        rest = rest[rest.index(after: close)...]
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop(while: \.isWhitespace)
        guard let (destination, afterDestination) = takeDestination(rest) else { return nil }
        let tail = afterDestination.drop(while: \.isWhitespace)
        guard let title = takeTitle(tail) else { return nil }
        return (label, MarkdownLinkReference(destination: destination, title: title.value))
    }

    /// A definition's optional title. A wrapper rather than a bare `String?`, because "there is no
    /// title" and "this is not a definition after all" are both answers this returns and collapsing
    /// them into one optional loses the second.
    private struct Title {
        let value: String?
    }

    private static func takeDestination(_ text: Substring) -> (String, Substring)? {
        if text.first == "<" {
            guard let close = unescapedIndex(of: ">", in: text.dropFirst()) else { return nil }
            let inner = text[text.index(after: text.startIndex)..<close]
            return (String(inner), text[text.index(after: close)...])
        }
        let destination = text.prefix { !$0.isWhitespace }
        guard !destination.isEmpty else { return nil }
        return (String(destination), text[destination.endIndex...])
    }

    /// The title, if any — and `nil` when what follows the destination is neither a title nor the
    /// end of the line. A definition must be the *whole* line, or a paragraph that opens with a
    /// bracketed phrase would be eaten.
    private static func takeTitle(_ text: Substring) -> Title? {
        if text.isEmpty { return Title(value: nil) }
        guard let open = text.first, let close = closer(for: open) else { return nil }
        let body = text.dropFirst()
        guard let end = unescapedIndex(of: close, in: body) else { return nil }
        guard MarkdownLine.isBlank(body[body.index(after: end)...]) else { return nil }
        return Title(value: String(body[body.startIndex..<end]))
    }

    private static func closer(for opener: Character) -> Character? {
        switch opener {
        case "\"": "\""
        case "'": "'"
        case "(": ")"
        default: nil
        }
    }

    /// The first `character` that is not preceded by a backslash.
    private static func unescapedIndex(
        of character: Character,
        in text: Substring
    ) -> Substring.Index? {
        var index = text.startIndex
        var escaped = false
        while index < text.endIndex {
            let current = text[index]
            if escaped {
                escaped = false
            } else if current == "\\" {
                escaped = true
            } else if current == character {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
}
