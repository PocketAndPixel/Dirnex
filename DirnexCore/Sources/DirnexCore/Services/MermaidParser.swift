import Foundation

/// A ```` ```mermaid ```` fence's body, read into a diagram (PLAN.md §M18 ▸ Slice 4).
///
/// One entry point and one job: decide **which** diagram this is, hand the rest to the parser that
/// knows that dialect, and name the type when it is neither. The type word is taken from the first
/// non-blank, non-comment line, which is where mermaid puts it and the only place it can be.
///
/// The vocabulary below is the *whole* boundary of the subset. A type in it that fails to parse
/// still falls back — `.unsupported` is returned for a `flowchart` with no readable statement in it
/// too, because a diagram with no nodes is a blank rectangle, which is a worse answer than the
/// source and a note.
enum MermaidParser {
    static func parse(_ source: String) -> MermaidDiagram {
        let lines = statements(in: source)
        guard let header = lines.first else { return .unsupported("") }
        let keyword = String(header.prefix(while: { !$0.isWhitespace }))

        switch keyword.lowercased() {
        case "graph", "flowchart":
            let rest = header.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            let chart = MermaidFlowchartParser.parse(
                Array(lines.dropFirst()),
                direction: MermaidFlowchart.Direction.named(rest) ?? .topDown
            )
            return chart.nodes.isEmpty ? .unsupported(keyword) : .flowchart(chart)
        case "sequencediagram":
            let sequence = MermaidSequenceParser.parse(Array(lines.dropFirst()))
            return sequence.participants.isEmpty ? .unsupported(keyword) : .sequence(sequence)
        default:
            return .unsupported(keyword)
        }
    }

    /// The fence's statements: comments and blank lines gone, indentation gone, and a line ending in
    /// a `;` separator split into the statements it holds.
    ///
    /// `%%` is mermaid's comment and it is stripped **outside quotes**, so a node label reading
    /// `A["100%% done"]` keeps its text. The same care is why the split on `;` is not a plain
    /// `components(separatedBy:)`.
    static func statements(in source: String) -> [String] {
        source
            .split(whereSeparator: \.isNewline)
            .flatMap { splitOutsideQuotes(stripComment(String($0)), on: ";") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func stripComment(_ line: String) -> String {
        let characters = Array(line)
        var quoted = false
        var index = 0
        while index < characters.count {
            if characters[index] == "\"" { quoted.toggle() }
            if !quoted, characters[index] == "%", index + 1 < characters.count,
               characters[index + 1] == "%" {
                return String(characters[..<index])
            }
            index += 1
        }
        return line
    }

    private static func splitOutsideQuotes(_ line: String, on separator: Character) -> [String] {
        guard line.contains(separator) else { return [line] }
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() }
            if character == separator, !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}
