import Foundation

/// Mermaid's front matter: a YAML block between two `---` lines opening a fence (PLAN.md §M39 ▸
/// Slice 14).
///
/// Mermaid's docs open their class and ER examples with one (`title: Animal example`, or a `config:`
/// naming a theme and a layout), and until Slice 14 such a fence fell back to its source for every
/// type, its note naming `---`. Only `title` is read, and drawn above the diagram as Mermaid draws
/// it. `config` is a configuration surface read from the diagram's source, which M39's own rule
/// keeps out (PLAN.md §M39), so it is skipped with everything else in the block.
///
/// Mermaid's own pattern is `^-{3}\s*\n(.*?\n)-{3}\s*\n+`, on text it has already trimmed: the first
/// line is `---`, and the block ends at the next line that is `---`. A block that never closes is no
/// front matter, and the fence falls back naming `---` as before.
enum MermaidFrontMatter {
    /// The fence's title, if its front matter names one, and its text with the front matter gone.
    static func split(_ source: String) -> (title: String?, body: String) {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.firstIndex(where: { !$0.allSatisfy(\.isWhitespace) }),
              isFence(lines[first]),
              let close = lines[(first + 1)...].firstIndex(where: isFence)
        else { return (nil, source) }
        let block = lines[(first + 1)..<close]
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (block.lazy.compactMap(title).first, body)
    }

    private static func isFence(_ line: Substring) -> Bool {
        line.hasPrefix("---") && line.dropFirst(3).allSatisfy(\.isWhitespace)
    }

    /// A top-level `title:` line's value, unquoted. An indented `title:` belongs to a block above it
    /// (`config:` has none, but a nested key of that name is not the diagram's).
    private static func title(_ line: Substring) -> String? {
        guard line.hasPrefix("title:") else { return nil }
        let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let text: String
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            text = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            text = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        } else if let comment = value.range(of: " #") {
            // YAML's comment after a plain value needs the space before it: `C#` is a title.
            text = value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        } else {
            text = value
        }
        return text.isEmpty ? nil : text
    }
}
