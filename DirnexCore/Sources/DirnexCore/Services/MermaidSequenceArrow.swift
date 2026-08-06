import Foundation

/// A message arrow found in a sequence statement (PLAN.md §M18 ▸ Slice 4).
struct MermaidSequenceArrowMatch: Equatable {
    let style: MermaidSequence.MessageStyle
    let start: Int
    let end: Int
}

/// Finding the arrow in `A->>B: text`.
///
/// The arrow is located **before** the colon is, and that ordering is the point: a message's text is
/// ordinary prose and may contain a colon or an arrow of its own — `A->>B: use -->> for a reply` is
/// a line somebody writes — so the arrow is what identifies a message, and the *first* colon after
/// it ends the target.
///
/// A participant id may contain a hyphen (`auth-service->>B: hi`), which is why a lone `-` is not an
/// arrow: every form here requires a tip after the dashes, and `-s` simply is not one.
enum MermaidSequenceArrow {
    static func first(in characters: [Character]) -> MermaidSequenceArrowMatch? {
        for index in characters.indices where characters[index] == "-" {
            if let match = scan(characters, at: index) { return match }
        }
        return nil
    }

    private static func scan(_ characters: [Character], at index: Int) -> MermaidSequenceArrowMatch? {
        var cursor = index + 1
        var isDashed = false
        if cursor < characters.count, characters[cursor] == "-" {
            isDashed = true
            cursor += 1
        }
        guard cursor < characters.count else { return nil }
        let style: MermaidSequence.MessageStyle
        var end = cursor + 1
        switch characters[cursor] {
        case ">":
            if cursor + 1 < characters.count, characters[cursor + 1] == ">" {
                style = isDashed ? .dashedArrow : .solidArrow
                end = cursor + 2
            } else {
                style = isDashed ? .dashedOpen : .solidOpen
            }
        case "x":
            style = .crossed(isDashed: isDashed)
        case ")":
            // Mermaid's async arrow. Outside the named subset as a *concept* — there is no
            // asynchrony to draw — but it is a message, and drawing it with an open head loses the
            // nuance rather than losing the line.
            style = isDashed ? .dashedOpen : .solidOpen
        default:
            return nil
        }
        return MermaidSequenceArrowMatch(style: style, start: index, end: end)
    }
}
