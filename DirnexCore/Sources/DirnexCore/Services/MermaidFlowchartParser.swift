import Foundation

/// A flowchart's statements, read into nodes and edges (PLAN.md §M18 ▸ Slice 4).
///
/// Every statement has the same shape — node references with edge operators between them — so one
/// routine reads `A`, `A --> B` and `A --> B --> C` alike, by splitting on the operators
/// `MermaidFlowchartLink` finds and treating what is left as node references. A statement with no
/// operator declares nodes and nothing else, which is exactly the one-group case of the same walk.
///
/// A node may be *referred to* before it is *labelled* (`A --> B`, then `B[Done]` three lines
/// later), so declarations accumulate: the first mention fixes a node's position in the drawing
/// order and any later one may still supply its label and shape.
enum MermaidFlowchartParser {
    static func parse(
        _ statements: [String],
        direction: MermaidFlowchart.Direction
    ) -> MermaidFlowchart {
        var builder = Builder()
        for statement in statements { builder.read(statement) }
        return MermaidFlowchart(
            direction: direction,
            nodes: builder.orderedNodes,
            edges: builder.edges,
            undrawn: builder.undrawn.sorted()
        )
    }

    /// The accumulating state of one parse. A struct the caller mutates, rather than a class: it is
    /// used from one function and never escapes it.
    private struct Builder {
        private var order: [String] = []
        private var seen: Set<String> = []
        private var labels: [String: String] = [:]
        private var shapes: [String: MermaidFlowchart.Shape] = [:]
        var edges: [MermaidFlowchart.Edge] = []
        var undrawn: Set<String> = []

        var orderedNodes: [MermaidFlowchart.Node] {
            order.map {
                MermaidFlowchart.Node(
                    id: $0,
                    label: labels[$0] ?? $0,
                    shape: shapes[$0] ?? .rectangle
                )
            }
        }

        mutating func read(_ statement: String) {
            if let keyword = Self.undrawnKeyword(in: statement) {
                undrawn.insert(keyword)
                return
            }
            var segments: [String] = []
            var links: [MermaidLink] = []
            var rest = Array(statement)
            while let link = MermaidFlowchartLink.first(in: rest) {
                segments.append(String(rest[..<link.start]))
                links.append(link)
                rest = Array(rest[link.end...])
            }
            segments.append(String(rest))

            let groups = segments.map { declare($0) }
            for (index, link) in links.enumerated() where index + 1 < groups.count {
                for from in groups[index] {
                    for to in groups[index + 1] {
                        edges.append(MermaidFlowchart.Edge(
                            from: from,
                            to: to,
                            label: link.label,
                            stroke: link.stroke,
                            tail: link.tail,
                            head: link.head
                        ))
                    }
                }
            }
        }

        /// One segment's node references. Mermaid's `&` joins several to one side of an edge
        /// (`A & B --> C`), which is a fan-out and not a node named `A & B` — reading it as the
        /// latter would put a node in the diagram nobody wrote.
        private mutating func declare(_ segment: String) -> [String] {
            MermaidFlowchartParser.split(segment, on: "&").compactMap { declareOne($0) }
        }

        private mutating func declareOne(_ text: String) -> String? {
            guard let reference = MermaidFlowchartParser.node(from: text) else { return nil }
            if seen.insert(reference.id).inserted { order.append(reference.id) }
            // A later mention may fill in what an earlier one left out, and must not blank it: the
            // bare `B` in `A --> B` carries no label, and overwriting `B[Done]` with it would erase
            // a label depending on which line came second.
            if let label = reference.label { labels[reference.id] = label }
            if let shape = reference.shape { shapes[reference.id] = shape }
            return reference.id
        }

        /// The statement's keyword when it is one this subset does not draw, or `nil` for an
        /// ordinary statement. `end` closes a `subgraph` and is reported under that name, so a
        /// diagram using one says "subgraph" once rather than twice under two spellings.
        private static func undrawnKeyword(in statement: String) -> String? {
            let word = statement.prefix(while: { !$0.isWhitespace }).lowercased()
            switch word {
            case "subgraph", "end": return "subgraph"
            case "style", "classdef", "class", "click", "linkstyle": return word
            // `direction` inside a subgraph re-points that subgraph only; with no subgraphs drawn
            // there is nothing for it to re-point, and it is silent rather than reported.
            case "direction": return "direction"
            default: return nil
            }
        }
    }

    // MARK: - Node references

    /// One mention of a node in a statement.
    ///
    /// `label` and `shape` are optional **independently of the id**, which is the whole point: a
    /// bare `B` says only that B exists, and must not overwrite what `B[Done]` said elsewhere.
    struct NodeReference {
        let id: String
        let label: String?
        let shape: MermaidFlowchart.Shape?
    }

    /// A node reference — `A`, `A[Start]`, `B{Yes?}`, `C((Done))` — or `nil` for a segment that
    /// holds no identifier at all.
    static func node(from text: String) -> NodeReference? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let characters = Array(trimmed)
        var index = 0
        while index < characters.count, !"([{".contains(characters[index]) { index += 1 }
        let id = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        guard index < characters.count else {
            return NodeReference(id: id, label: nil, shape: nil)
        }

        let body = String(characters[index...])
        for bracket in brackets
            where body.hasPrefix(bracket.open) && body.hasSuffix(bracket.close) {
            let inner = body.dropFirst(bracket.open.count).dropLast(bracket.close.count)
            return NodeReference(id: id, label: unquoted(String(inner)), shape: bracket.shape)
        }
        // An unrecognized bracket pair keeps its text and draws as a rectangle, rather than losing
        // the node: the same "an unreadable construct falls back to its literal text" rule the rest
        // of the renderer keeps.
        return NodeReference(id: id, label: unquoted(body), shape: .rectangle)
    }

    /// A bracket pair and the outline it names.
    private struct Bracket {
        let open: String
        let close: String
        let shape: MermaidFlowchart.Shape
    }

    /// **Ordered, not a dictionary**: `[[x]]` has to be tested before `[x]` and `((x))` before
    /// `(x)`, since the shorter pair matches the longer one's text too. First match wins, so this
    /// order is the rule rather than a convenience.
    private static let brackets: [Bracket] = [
        Bracket(open: "[[", close: "]]", shape: .subroutine),
        Bracket(open: "((", close: "))", shape: .circle),
        Bracket(open: "[", close: "]", shape: .rectangle),
        Bracket(open: "(", close: ")", shape: .rounded),
        Bracket(open: "{", close: "}", shape: .diamond)
    ]

    /// A label's surrounding quotes removed. Mermaid uses them to carry a character the brackets
    /// would otherwise end on, so they are syntax and never part of what is drawn.
    private static func unquoted(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else {
            return trimmed.isEmpty ? nil : trimmed
        }
        let inner = String(trimmed.dropFirst().dropLast())
        return inner.isEmpty ? nil : inner
    }

    /// `text` split on `separator`, ignoring any inside brackets or quotes — where a `&` is part of
    /// somebody's label rather than a fan-out.
    static func split(_ text: String, on separator: Character) -> [String] {
        guard text.contains(separator) else { return [text] }
        var parts: [String] = []
        var current = ""
        var depth = 0
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if "([{".contains(character) { depth += 1 }
                if ")]}".contains(character) { depth = max(0, depth - 1) }
                if character == separator, depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(character)
        }
        parts.append(current)
        return parts
    }
}
