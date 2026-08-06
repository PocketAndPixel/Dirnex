import Foundation

/// One edge operator, found in a flowchart statement (PLAN.md §M18 ▸ Slice 4).
struct MermaidLink: Equatable {
    let stroke: MermaidFlowchart.Stroke
    let tail: MermaidFlowchart.Tip
    let head: MermaidFlowchart.Tip
    let label: String?
    /// Where the operator begins and ends in the statement's characters. The text before `start` is
    /// the source node and the text after `end` is the target — which is what lets a chain
    /// (`A --> B --> C`) be read by finding one link and recursing on what is left.
    let start: Int
    let end: Int
}

/// Finding the edge operator in a flowchart statement.
///
/// Its own file because it is the one genuinely fiddly piece of the dialect, and because the shape
/// that reads well is a scanner with several small exits rather than one predicate. Mermaid writes
/// the same edge four ways — `-->`, `-.->`, `==>`, and the two label forms `-->|text|` and
/// `-- text -->` — and the arrow's *length* carries meaning too: `--` is a link only with a head,
/// while `---` is one without.
///
/// The scan skips bracketed and quoted regions, so `A[a --> b] --> C` finds the **second** operator.
/// Getting that wrong is not a syntax error, it is a diagram with a node named `A[a` in it.
enum MermaidFlowchartLink {
    /// The first edge operator outside any bracket or quote, or `nil` for a statement that declares
    /// a node and nothing else.
    static func first(in characters: [Character]) -> MermaidLink? {
        var depth = 0
        var quoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" { quoted.toggle() }
            if !quoted {
                if "([{".contains(character) { depth += 1 }
                if ")]}".contains(character) { depth = max(0, depth - 1) }
                if depth == 0, let link = scan(characters, at: index) { return link }
            }
            index += 1
        }
        return nil
    }

    /// What is known about an operator part-way through reading it: where it began, its stroke,
    /// and the tip on its tail.
    ///
    /// One value rather than three parameters threaded through five functions — the scan hands it
    /// along unchanged, and the only thing any stage adds is where the operator *ends*.
    private struct Partial {
        let start: Int
        let stroke: MermaidFlowchart.Stroke
        let tail: MermaidFlowchart.Tip

        /// The character a run of this stroke is made of. `.dotted` has no single one — it is
        /// `-.-` — and never asks.
        var runCharacter: Character { stroke == .thick ? "=" : "-" }
    }

    /// An operator starting exactly at `index`, or `nil` — the caller advances one character and
    /// asks again, so this may say no as often as it likes.
    private static func scan(_ characters: [Character], at index: Int) -> MermaidLink? {
        var cursor = index
        var tail = MermaidFlowchart.Tip.none
        switch characters[index] {
        case "<":
            tail = .arrow
            cursor += 1
        case "x", "o":
            // A tail tip only when it *opens* a link: `A x--x B`. Without the two tests below, a
            // node id ending in x or o would swallow its own last letter into the operator, which
            // draws a diagram naming a node nobody wrote.
            guard index == 0 || characters[index - 1].isWhitespace,
                  index + 1 < characters.count,
                  characters[index + 1] == "-" || characters[index + 1] == "="
            else { return nil }
            tail = characters[index] == "x" ? .cross : .circle
            cursor += 1
        case "-", "=":
            break
        default:
            return nil
        }
        guard cursor < characters.count else { return nil }
        if characters[cursor] == "-", cursor + 1 < characters.count, characters[cursor + 1] == "." {
            return dotted(
                characters,
                Partial(start: index, stroke: .dotted, tail: tail),
                body: cursor
            )
        }
        if characters[cursor] == "-" {
            return run(characters, Partial(start: index, stroke: .solid, tail: tail), body: cursor)
        }
        if characters[cursor] == "=" {
            return run(characters, Partial(start: index, stroke: .thick, tail: tail), body: cursor)
        }
        return nil
    }

    /// A run of `character` — `--`, `---`, `==` — and whatever follows it.
    ///
    /// The length rule is mermaid's and is easy to get backwards: **two** is a link only when a head
    /// follows (`-->`), **three or more** is a link on its own (`---`), and a bare two with no head
    /// is the *opening* half of `-- text -->`.
    private static func run(
        _ characters: [Character],
        _ partial: Partial,
        body: Int
    ) -> MermaidLink? {
        var cursor = body
        while cursor < characters.count, characters[cursor] == partial.runCharacter { cursor += 1 }
        let length = cursor - body
        guard length >= 2 else { return nil }
        let (head, afterHead) = tip(characters, at: cursor)
        if head != .none {
            return finish(characters, partial, end: afterHead, head: head)
        }
        if length >= 3 {
            return finish(characters, partial, end: cursor, head: .none)
        }
        return opener(characters, partial, text: cursor)
    }

    /// `-.->`, `-.-`, or the opening half of `-. text .->`.
    private static func dotted(
        _ characters: [Character],
        _ partial: Partial,
        body: Int
    ) -> MermaidLink? {
        var cursor = body + 1
        while cursor < characters.count, characters[cursor] == "." { cursor += 1 }
        guard cursor < characters.count, characters[cursor] == "-" else {
            return opener(characters, partial, text: cursor)
        }
        cursor += 1
        let (head, afterHead) = tip(characters, at: cursor)
        return finish(characters, partial, end: head == .none ? cursor : afterHead, head: head)
    }

    /// The `-- text -->` family: read forward for the closing half and take everything between as
    /// the label. No closer means this was never an operator — `A -- B` is not an edge — so the
    /// caller moves on rather than inventing one.
    private static func opener(
        _ characters: [Character],
        _ partial: Partial,
        text: Int
    ) -> MermaidLink? {
        var cursor = text
        while cursor < characters.count {
            if let (head, end) = closer(characters, at: cursor, stroke: partial.stroke) {
                let label = String(characters[text..<cursor]).trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { return nil }
                return finish(characters, partial, end: end, head: head, label: label)
            }
            cursor += 1
        }
        return nil
    }

    /// The closing half of a labelled operator: `-->` for solid, `.->` for dotted, `==>` for thick.
    private static func closer(
        _ characters: [Character],
        at index: Int,
        stroke: MermaidFlowchart.Stroke
    ) -> (MermaidFlowchart.Tip, Int)? {
        var cursor = index
        switch stroke {
        case .solid, .thick:
            let character: Character = stroke == .solid ? "-" : "="
            guard characters[cursor] == character else { return nil }
            while cursor < characters.count, characters[cursor] == character { cursor += 1 }
            guard cursor - index >= 2 else { return nil }
        case .dotted:
            guard characters[cursor] == "." else { return nil }
            while cursor < characters.count, characters[cursor] == "." { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == "-" else { return nil }
            cursor += 1
        }
        let (head, afterHead) = tip(characters, at: cursor)
        return (head, head == .none ? cursor : afterHead)
    }

    private static func tip(_ characters: [Character], at index: Int) -> (MermaidFlowchart.Tip, Int) {
        guard index < characters.count else { return (.none, index) }
        switch characters[index] {
        case ">": return (.arrow, index + 1)
        case "x": return (.cross, index + 1)
        case "o": return (.circle, index + 1)
        default: return (.none, index)
        }
    }

    /// The operator is read; take the `|text|` label if one follows it.
    ///
    /// Both label spellings end here, which is what keeps them one concept: `-->|yes|` and
    /// `-- yes -->` produce the same `MermaidLink`, so nothing downstream knows there were two.
    private static func finish(
        _ characters: [Character],
        _ partial: Partial,
        end: Int,
        head: MermaidFlowchart.Tip,
        label: String? = nil
    ) -> MermaidLink {
        func link(_ label: String?, end: Int) -> MermaidLink {
            MermaidLink(
                stroke: partial.stroke,
                tail: partial.tail,
                head: head,
                label: label,
                start: partial.start,
                end: end
            )
        }
        var cursor = end
        while cursor < characters.count, characters[cursor] == " " { cursor += 1 }
        guard label == nil, cursor < characters.count, characters[cursor] == "|" else {
            return link(label, end: end)
        }
        var closing = cursor + 1
        while closing < characters.count, characters[closing] != "|" { closing += 1 }
        guard closing < characters.count else { return link(nil, end: end) }
        let text = String(characters[(cursor + 1)..<closing]).trimmingCharacters(in: .whitespaces)
        return link(
            text.isEmpty ? nil : text,
            end: closing + 1
        )
    }
}
