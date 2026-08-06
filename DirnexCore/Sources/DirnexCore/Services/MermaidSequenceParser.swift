import Foundation

/// A sequence diagram's statements, read into participants and events (PLAN.md §M18 ▸ Slice 4).
///
/// Simpler than the flowchart's, and for a structural reason rather than a lucky one: a sequence
/// diagram is **positional**. Time runs down the page in the order the statements are written, so
/// the parse produces a list rather than a graph and there is no layout to speak of afterwards —
/// only column and row arithmetic.
///
/// A participant may be declared (`participant A as Alice`) or merely used (`A->>B: hi`), and both
/// place it. Declaration order wins where both happen, which is why a file that names its
/// participants up front gets them in that order across the top.
enum MermaidSequenceParser {
    static func parse(_ statements: [String]) -> MermaidSequence {
        var builder = Builder()
        for statement in statements { builder.read(statement) }
        return MermaidSequence(
            participants: builder.orderedParticipants,
            events: builder.events,
            undrawn: builder.undrawn.sorted()
        )
    }

    private struct Builder {
        private var order: [String] = []
        private var seen: Set<String> = []
        private var labels: [String: String] = [:]
        private var actors: Set<String> = []
        var events: [MermaidSequence.Event] = []
        var undrawn: Set<String> = []

        var orderedParticipants: [MermaidSequence.Participant] {
            order.map {
                MermaidSequence.Participant(
                    id: $0,
                    label: labels[$0] ?? $0,
                    isActor: actors.contains($0)
                )
            }
        }

        mutating func read(_ statement: String) {
            let keyword = statement.prefix(while: { !$0.isWhitespace }).lowercased()
            let rest = statement.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            switch keyword {
            case "participant", "actor":
                declare(rest, isActor: keyword == "actor")
            case "activate":
                if !rest.isEmpty { events.append(.activate(place(rest))) }
            case "deactivate":
                if !rest.isEmpty { events.append(.deactivate(place(rest))) }
            case "note":
                note(rest)
            case "loop", "alt", "opt", "par", "critical", "break", "rect", "autonumber", "box":
                // A grouping construct. Its *contents* still draw — dropping them would lose real
                // messages — but the frame around them does not, and `undrawn` is what says so.
                undrawn.insert(keyword)
            case "else", "and", "end":
                // Continuations of the constructs above, which have already reported. Naming these
                // too would list one `alt` under two words and read as two omissions.
                break
            default:
                message(statement)
            }
        }

        /// `participant A as Alice` — the alias is what is drawn, the id is what messages name.
        private mutating func declare(_ text: String, isActor: Bool) {
            let (id, alias) = MermaidSequenceParser.splitAlias(text)
            guard !id.isEmpty else { return }
            _ = place(id)
            if let alias { labels[id] = alias }
            if isActor { actors.insert(id) }
        }

        /// Registers a participant if it is new and hands back its id.
        @discardableResult
        private mutating func place(_ id: String) -> String {
            let trimmed = id.trimmingCharacters(in: .whitespaces)
            if seen.insert(trimmed).inserted { order.append(trimmed) }
            return trimmed
        }

        /// `Note over A,B: text`, `Note right of A: text`.
        private mutating func note(_ text: String) {
            let lowered = text.lowercased()
            let placement: MermaidSequence.NotePlacement
            var rest: Substring
            if lowered.hasPrefix("over") {
                placement = .over
                rest = text.dropFirst("over".count)
            } else if lowered.hasPrefix("right of") {
                placement = .rightOf
                rest = text.dropFirst("right of".count)
            } else if lowered.hasPrefix("left of") {
                placement = .leftOf
                rest = text.dropFirst("left of".count)
            } else {
                return
            }
            guard let colon = rest.firstIndex(of: ":") else { return }
            let names = rest[..<colon]
                .split(separator: ",")
                .map { place(String($0)) }
                .filter { !$0.isEmpty }
            let body = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !names.isEmpty, !body.isEmpty else { return }
            events.append(.note(placement: placement, participants: names, text: body))
        }

        /// `A->>B: text`, with mermaid's `+`/`-` activation suffixes on the target.
        ///
        /// The arrow is found before the colon is, because a message's *text* may contain either —
        /// "A->>B: use -->> for a reply" is an ordinary line — and the arrow is the token that says
        /// this is a message at all.
        private mutating func message(_ statement: String) {
            guard let arrow = MermaidSequenceArrow.first(in: Array(statement)) else { return }
            let from = place(String(statement.prefix(arrow.start)))
            let tail = Array(statement)[arrow.end...]
            let colon = tail.firstIndex(of: ":")
            let targetText = String(colon.map { tail[..<$0] } ?? tail[...])
                .trimmingCharacters(in: .whitespaces)
            let text = colon
                .map { String(tail[tail.index(after: $0)...]).trimmingCharacters(in: .whitespaces) }
                ?? ""
            // `A->>+B` activates B on arrival and `A->>-B` deactivates it. The sign rides on the
            // *target*, so it is stripped here rather than in the arrow scanner.
            var target = targetText
            var activation: MermaidSequence.Event?
            if target.hasPrefix("+") {
                target = String(target.dropFirst())
                activation = .activate(target.trimmingCharacters(in: .whitespaces))
            } else if target.hasPrefix("-") {
                target = String(target.dropFirst())
                activation = .deactivate(target.trimmingCharacters(in: .whitespaces))
            }
            let to = place(target)
            guard !from.isEmpty, !to.isEmpty else { return }
            events.append(.message(from: from, to: to, text: text, style: arrow.style))
            if let activation { events.append(activation) }
        }
    }

    /// `A as Alice` split into its id and its alias. The separator is the **word** `as`, so a
    /// participant genuinely called `Fast` keeps its name.
    static func splitAlias(_ text: String) -> (String, String?) {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        guard let index = words.firstIndex(where: { $0.lowercased() == "as" }),
              index > 0, index + 1 < words.count
        else {
            return (text.trimmingCharacters(in: .whitespaces), nil)
        }
        return (
            words[..<index].joined(separator: " "),
            words[(index + 1)...].joined(separator: " ")
        )
    }
}
