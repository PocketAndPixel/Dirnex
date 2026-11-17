import Foundation

/// A state diagram's statements, read into states, regions and transitions (PLAN.md §M39 ▸
/// Slice 13).
///
/// One statement per line, and **no `;` separator**: the flowchart's splitter would cut
/// `a --> b : x; y` into a transition and a state called `y`, which Mermaid's state grammar never
/// does. Blocks nest with `state X {` and `}`, and `--` starts the next region of the block it is
/// in. Every rule that is Mermaid's rather than obvious is stated on `MermaidStateDiagram`.
enum MermaidStateParser {
    static func parse(_ statements: [String]) -> MermaidStateDiagram {
        var builder = MermaidStateBuilder()
        var index = 0
        while index < statements.count {
            index = builder.read(statements, at: index)
        }
        return builder.diagram
    }

    // MARK: - Pieces of a statement

    /// `id` without a `:::class` styling suffix, which names a `classDef` and is not part of the
    /// state's name. `Crash:::bad` is the state `Crash`.
    static func bareID(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let range = trimmed.range(of: ":::") else { return trimmed }
        return String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// The position of the first `:` that separates a description or a label, skipping any `:::`
    /// styling suffix — `A:::hot : warm` describes `A` as "warm".
    static func separator(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == ":" {
                if text[index...].hasPrefix(":::") {
                    index = text.index(index, offsetBy: 3)
                    while index < text.endIndex, !text[index].isWhitespace, text[index] != ":" {
                        index = text.index(after: index)
                    }
                    continue
                }
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// The text after a separator, trimmed, or `nil` when there is none.
    static func after(_ index: String.Index, in text: String) -> String? {
        let rest = text[text.index(after: index)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// A `<<choice>>`, `<<fork>>` or `<<join>>` marker, also spelled with double brackets.
    static func kind(marker text: String) -> MermaidStateDiagram.Kind? {
        let lowered = text.lowercased()
        for (word, kind) in [
            ("choice", MermaidStateDiagram.Kind.choice),
            ("fork", .fork),
            ("join", .join)
        ] where lowered.contains("<<\(word)>>") || lowered.contains("[[\(word)]]") {
            return kind
        }
        return nil
    }

    /// `"text"` without its quotes; anything else as written.
    static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }
}
