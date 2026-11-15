import Foundation

/// One relation statement's left of its label, read: `A "1" <|-- "*" B` (PLAN.md §M39 ▸ Slice 14).
///
/// The line is `--` or `..`, found outside quotes and backticks, since a cardinality is often
/// `"0..1"`. Each end's marker is what touches the line on that side: `<|`, `*`, `o`, `<` or `()`
/// on the left, `|>`, `*`, `o`, `>` or `()` on the right. An `o` counts only standing alone — after
/// a space or a quote on the left, before one on the right — so `foo--bar` is `foo` and `bar`, not
/// an aggregation of `fo`.
struct MermaidClassRelationSyntax {
    typealias End = MermaidClassDiagram.End

    let from: (id: String, generic: String?)
    let to: (id: String, generic: String?)
    let fromEnd: End
    let toEnd: End
    let isDashed: Bool
    let fromCardinality: String?
    let toCardinality: String?

    /// The relation in `head`, the statement up to its label's colon, or `nil` when it holds none.
    static func read(_ head: String) -> MermaidClassRelationSyntax? {
        let characters = Array(head)
        guard let line = lineStart(in: characters) else { return nil }
        let (fromEnd, leftCut) = leftEnd(characters, line: line)
        let (toEnd, rightCut) = rightEnd(characters, after: line + 2)
        let left = cardinality(ending: String(characters[..<leftCut]))
        let right = cardinality(starting: String(characters[rightCut...]))
        guard let from = MermaidClassParser.name(at: Substring(left.rest)),
              let to = MermaidClassParser.name(at: Substring(right.rest))
        else { return nil }
        return MermaidClassRelationSyntax(
            from: (from.id, from.generic),
            to: (to.id, to.generic),
            fromEnd: fromEnd,
            toEnd: toEnd,
            isDashed: characters[line] == ".",
            fromCardinality: left.cardinality,
            toCardinality: right.cardinality
        )
    }

    /// Where the first `--` or `..` outside quotes and backticks starts.
    private static func lineStart(in characters: [Character]) -> Int? {
        var quote: Character?
        var index = 0
        while index + 1 < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "`" {
                quote = character
            } else if character == "-" || character == ".", characters[index + 1] == character {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func leftEnd(_ characters: [Character], line: Int) -> (End, Int) {
        let before = String(characters[max(0, line - 2)..<line])
        if before == "<|" { return (.extension, line - 2) }
        if before == "()" { return (.lollipop, line - 2) }
        guard line > 0 else { return (.none, line) }
        switch characters[line - 1] {
        case "*": return (.composition, line - 1)
        case "<": return (.arrow, line - 1)
        case "o" where line == 1 || characters[line - 2].isWhitespace || characters[line - 2] == "\"":
            return (.aggregation, line - 1)
        default: return (.none, line)
        }
    }

    private static func rightEnd(_ characters: [Character], after line: Int) -> (End, Int) {
        let next = String(characters[min(line, characters.count)..<min(line + 2, characters.count)])
        if next == "|>" { return (.extension, line + 2) }
        if next == "()" { return (.lollipop, line + 2) }
        guard line < characters.count else { return (.none, line) }
        let following = line + 1 < characters.count ? characters[line + 1] : " "
        switch characters[line] {
        case "*": return (.composition, line + 1)
        case ">": return (.arrow, line + 1)
        case "o" where following.isWhitespace || following == "\"": return (.aggregation, line + 1)
        default: return (.none, line)
        }
    }

    /// A quoted cardinality at the end of the left side, and what is before it.
    private static func cardinality(ending text: String) -> (cardinality: String?, rest: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("\""), let open = trimmed.dropLast().lastIndex(of: "\"") else {
            return (nil, trimmed)
        }
        let value = String(
            trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
        )
        return (MermaidText.decoded(value), String(trimmed[..<open]))
    }

    /// A quoted cardinality at the start of the right side, and what is after it.
    private static func cardinality(starting text: String) -> (cardinality: String?, rest: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), let close = trimmed.dropFirst().firstIndex(of: "\"") else {
            return (nil, trimmed)
        }
        let value = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
        return (MermaidText.decoded(value), String(trimmed[trimmed.index(after: close)...]))
    }

    /// Where a relation's label starts: the first `:` outside quotes and backticks that is not part
    /// of a `:::style` suffix. The same colon divides `X : member`.
    static func colon(in text: String) -> String.Index? {
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "`" {
                quote = character
            } else if character == ":" {
                guard text[index...].hasPrefix(":::") else { return index }
                index = text.index(index, offsetBy: 3)
                while index < text.endIndex, !text[index].isWhitespace, text[index] != ":" {
                    index = text.index(after: index)
                }
                continue
            }
            index = text.index(after: index)
        }
        return nil
    }
}
