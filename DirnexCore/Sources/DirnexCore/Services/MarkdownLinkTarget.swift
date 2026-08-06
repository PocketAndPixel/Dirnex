import Foundation

/// What follows a link's `[label]` — the four forms a destination can take (PLAN.md §M18 ▸ Slice 1).
///
/// Split out of the scanner because all four end the same way and only the middle differs:
/// `[text](url "title")` carries its own, `[text][label]` and `[text][]` name a definition, and the
/// bare `[label]` shortcut is the same lookup with the text as its own key. Refusing (`nil`) is a
/// first-class answer, and the common one — most brackets in prose are brackets.
enum MarkdownLinkTarget {
    struct Target: Equatable {
        let destination: String
        let title: String?
        /// One past the last character consumed, so the scanner resumes cleanly.
        let end: Int
    }

    static func take(
        _ characters: [Character],
        after close: Int,
        label: String,
        references: [String: MarkdownLinkReference]
    ) -> Target? {
        let next = close + 1
        if next < characters.count, characters[next] == "(" {
            return inline(characters, from: next)
        }
        if next < characters.count, characters[next] == "[" {
            guard let end = characters[next...].firstIndex(of: "]") else {
                return reference(label, references, end: next)
            }
            let named = String(characters[(next + 1)..<end])
            // `[text][]` is the collapsed form: the text is its own label.
            return reference(named.isEmpty ? label : named, references, end: end + 1)
        }
        return reference(label, references, end: next)
    }

    private static func reference(
        _ label: String,
        _ references: [String: MarkdownLinkReference],
        end: Int
    ) -> Target? {
        guard let found = references[MarkdownLinkReference.key(for: label)] else { return nil }
        return Target(destination: found.destination, title: found.title, end: end)
    }

    /// `(destination "title")`, with the destination optionally in angle brackets — which is how a
    /// URL containing a space is written, and a path in this repo's own docs sometimes does.
    private static func inline(_ characters: [Character], from open: Int) -> Target? {
        var cursor = open + 1
        skipWhitespace(characters, &cursor)
        guard let destination = takeDestination(characters, &cursor) else { return nil }
        skipWhitespace(characters, &cursor)
        var title: String?
        if cursor < characters.count, let closer = titleCloser(characters[cursor]) {
            guard let end = index(of: closer, in: characters, from: cursor + 1) else { return nil }
            title = String(characters[(cursor + 1)..<end])
            cursor = end + 1
            skipWhitespace(characters, &cursor)
        }
        guard cursor < characters.count, characters[cursor] == ")" else { return nil }
        return Target(destination: destination, title: title, end: cursor + 1)
    }

    private static func takeDestination(_ characters: [Character], _ cursor: inout Int) -> String? {
        if cursor < characters.count, characters[cursor] == "<" {
            guard let end = index(of: ">", in: characters, from: cursor + 1) else { return nil }
            let destination = String(characters[(cursor + 1)..<end])
            cursor = end + 1
            return destination
        }
        var depth = 0
        var text = ""
        while cursor < characters.count {
            let character = characters[cursor]
            if character == "\\", cursor + 1 < characters.count {
                text.append(characters[cursor + 1])
                cursor += 2
                continue
            }
            // A destination may hold balanced parentheses, which is what a Wikipedia URL and a
            // `foo(bar)` anchor both need; the first *unbalanced* `)` ends it.
            if character == "(" { depth += 1 }
            if character == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            if character.isWhitespace { break }
            text.append(character)
            cursor += 1
        }
        return text.isEmpty ? "" : text
    }

    private static func titleCloser(_ opener: Character) -> Character? {
        switch opener {
        case "\"": "\""
        case "'": "'"
        case "(": ")"
        default: nil
        }
    }

    private static func index(
        of character: Character,
        in characters: [Character],
        from start: Int
    ) -> Int? {
        var cursor = start
        while cursor < characters.count {
            if characters[cursor] == "\\" {
                cursor += 2
                continue
            }
            if characters[cursor] == character { return cursor }
            if characters[cursor] == "\n" { return nil }
            cursor += 1
        }
        return nil
    }

    private static func skipWhitespace(_ characters: [Character], _ cursor: inout Int) {
        while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
    }
}
