import Foundation

/// YAML front matter at the top of a `.md` (PLAN.md §M18 ▸ Slice 1).
///
/// Recognized rather than parsed. A `---` fence at the very top of a file is otherwise a thematic
/// break, and the block under it a paragraph — so a note taken in any of the tools that write front
/// matter opens with a rule, its own metadata as prose, and another rule. It is read for **display**
/// only, which is why this is not a YAML parser: a nested value keeps the text it was written as,
/// under the key that introduced it, and renders as that text.
enum MarkdownFrontMatter {
    /// Take the front-matter block off the top of `lines`, or leave them untouched and answer `nil`.
    ///
    /// Three conditions, and the third is what keeps an ordinary rule-paragraph-rule document from
    /// being read as metadata: the file opens with `---`, a closing `---` or `...` follows, and the
    /// first line between them looks like a `key:` — which real front matter always does.
    static func take(from lines: inout [String]) -> [MarkdownFrontMatterEntry]? {
        guard let first = lines.first, isFence(first, opening: true) else { return nil }
        guard let close = lines.dropFirst().firstIndex(where: { isFence($0, opening: false) })
        else { return nil }
        let body = Array(lines[1..<close])
        guard let lead = body.first(where: { !MarkdownLine.isBlank($0) }), keyEnd(of: lead) != nil
        else { return nil }
        lines.removeSubrange(0...close)
        return body.compactMap(entry)
    }

    private static func isFence(_ line: String, opening: Bool) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "---" || (!opening && trimmed == "...")
    }

    private static func entry(from line: String) -> MarkdownFrontMatterEntry? {
        guard !MarkdownLine.isBlank(line) else { return nil }
        guard let end = keyEnd(of: line) else {
            // A continuation or a list item under the key above it. Kept, under an empty key, so
            // the value is shown rather than silently dropped — the panel draws it unlabelled.
            return MarkdownFrontMatterEntry(
                key: "",
                value: line.trimmingCharacters(in: .whitespaces)
            )
        }
        let key = String(line[line.startIndex..<end]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        return MarkdownFrontMatterEntry(key: key, value: unquoted(value))
    }

    /// The index of the `:` closing a top-level key, or `nil` when this line does not start one.
    /// Top-level means unindented — an indented `key:` belongs to the structure above it, and
    /// promoting it would flatten a mapping into a list of unrelated rows.
    private static func keyEnd(of line: String) -> String.Index? {
        guard MarkdownLine.indentation(of: line) == 0 else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[line.startIndex..<colon]
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return colon
    }

    /// A quoted scalar without its quotes. Front matter routinely quotes a value that contains a
    /// colon, and showing the quotes would be showing the reader the file's syntax rather than
    /// what it says.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let quote = value.first, quote == "\"" || quote == "'",
              value.last == quote
        else { return value }
        return String(value.dropFirst().dropLast())
    }
}
