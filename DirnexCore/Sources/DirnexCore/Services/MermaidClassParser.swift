import Foundation

/// A class diagram's statements, read into classes, namespaces and relations (PLAN.md §M39 ▸
/// Slice 14).
///
/// One statement per line and no `;` separator: the corpus's class diagram writes `&lt;rw&gt;` in
/// its members, and a split on `;` would cut every one of them in half. The reading is
/// `MermaidClassBuilder`'s; this file holds the pieces of a statement, each one Mermaid's own rule.
enum MermaidClassParser {
    static func parse(_ statements: [String]) -> MermaidClassDiagram {
        var builder = MermaidClassBuilder()
        var index = 0
        while index < statements.count {
            index = builder.read(statements, at: index)
        }
        return builder.diagram
    }

    // MARK: - Names

    /// A class reference read off the start of a statement.
    struct Name {
        let id: String
        /// The name with its generic drawn, `Name<T>`, when it was written with one.
        let generic: String?
        /// What follows the reference.
        let rest: Substring
    }

    /// A class reference at the start of `text`: `` `Name with spaces` ``, `Name`, `Name~T~`, with
    /// any `:::style` suffix dropped.
    static func name(at text: Substring) -> Name? {
        let text = text.drop(while: \.isWhitespace)
        if text.hasPrefix("`") {
            guard let close = text.dropFirst().firstIndex(of: "`") else { return nil }
            let id = String(text[text.index(after: text.startIndex)..<close])
            return id.isEmpty ? nil : Name(
                id: id,
                generic: nil,
                rest: text[text.index(after: close)...]
            )
        }
        var end = text.startIndex
        var inGeneric = false
        while end < text.endIndex {
            let character = text[end]
            if character == "~" {
                inGeneric.toggle()
            } else if !inGeneric, character.isWhitespace || "[{\":<".contains(character) {
                break
            }
            end = text.index(after: end)
        }
        let token = String(text[..<end])
        guard let tilde = token.firstIndex(of: "~") else {
            return token.isEmpty ? nil : Name(
                id: token,
                generic: nil,
                rest: stripStyle(text[end...])
            )
        }
        let id = String(token[..<tilde])
        guard !id.isEmpty else { return nil }
        return Name(
            id: id,
            generic: id + generics(String(token[tilde...])),
            rest: stripStyle(text[end...])
        )
    }

    /// `rest` past a `:::style` suffix, which names a `classDef` and is not part of the name.
    private static func stripStyle(_ rest: Substring) -> Substring {
        guard rest.hasPrefix(":::") else { return rest }
        return rest.dropFirst(3).drop { !$0.isWhitespace && !"[{<".contains($0) }
    }

    // MARK: - Generics

    /// `~` pairs as angle brackets, Mermaid's `parseGenericTypes`: split at commas, a `~K` and a
    /// ` V~` either side of one joined back up, and each piece paired from the outside in.
    static func generics(_ text: String) -> String {
        guard text.contains("~") else { return text }
        var sets: [String] = []
        var current = ""
        for character in text {
            if character == "," {
                sets.append(current)
                sets.append(",")
                current = ""
            } else {
                current.append(character)
            }
        }
        sets.append(current)
        var output: [String] = []
        var index = 0
        while index < sets.count {
            var piece = sets[index]
            if piece == ",", index > 0, index + 1 < sets.count,
               tildes(in: sets[index - 1]) == 1, tildes(in: sets[index + 1]) == 1 {
                piece = (output.popLast() ?? "") + "," + sets[index + 1]
                index += 1
                output.append(paired(piece))
            } else {
                output.append(paired(piece))
            }
            index += 1
        }
        return output.joined()
    }

    private static func tildes(in text: String) -> Int {
        text.reduce(0) { $1 == "~" ? $0 + 1 : $0 }
    }

    /// One piece's tildes paired outermost first; an odd one at the start is left as it was.
    private static func paired(_ text: String) -> String {
        guard tildes(in: text) > 1 else { return text }
        var characters = Array(text)
        var leading = false
        if tildes(in: text) % 2 != 0, characters.first == "~" {
            characters.removeFirst()
            leading = true
        }
        while let first = characters.firstIndex(of: "~"),
              let last = characters.lastIndex(of: "~"), first != last {
            characters[first] = "<"
            characters[last] = ">"
        }
        return (leading ? "~" : "") + String(characters)
    }

    // MARK: - Members

    /// A member line as drawn — Mermaid's `ClassMember`. A method is any line with a `)` after its
    /// first character; its `$` or `*` may sit straight after the `)` or at the very end.
    static func member(_ raw: String) -> MermaidClassDiagram.Member {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard line.dropFirst().contains(")") else { return attribute(line) }
        return method(line) ?? attribute(line)
    }

    private static let visibilities: Set<Character> = ["+", "-", "#", "~"]

    private static func attribute(_ line: String) -> MermaidClassDiagram.Member {
        var body = Substring(line)
        var visibility = ""
        if let first = body.first, visibilities.contains(first) {
            visibility = String(first)
            body = body.dropFirst()
        }
        var classifier: Character?
        if let last = body.last, last == "$" || last == "*" {
            classifier = last
            body = body.dropLast()
        }
        return MermaidClassDiagram.Member(
            text: MermaidText.decoded(
                visibility + generics(body.trimmingCharacters(in: .whitespaces))
            ),
            isStatic: classifier == "$",
            isAbstract: classifier == "*"
        )
    }

    /// `([#+~-])?(.+)\((.*)\)([\s$*])?(.*)`, the greedy groups included: the name runs to the last
    /// `(` that a `)` follows, and the parameters to the last `)`.
    private static func method(_ line: String) -> MermaidClassDiagram.Member? {
        guard let close = line.lastIndex(of: ")"),
              let open = line[..<close].lastIndex(of: "("),
              open > line.startIndex
        else { return nil }
        var head = line[..<open]
        var visibility = ""
        if let first = head.first, visibilities.contains(first), head.count > 1 {
            visibility = String(first)
            head = head.dropFirst()
        }
        let parameters = line[line.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        var tail = line[line.index(after: close)...]
        var classifier: Character?
        if let first = tail.first, first == "$" || first == "*" {
            classifier = first
            tail = tail.dropFirst()
        }
        var returnType = tail.trimmingCharacters(in: .whitespaces)
        if classifier == nil, let last = returnType.last, last == "$" || last == "*" {
            classifier = last
            returnType = String(returnType.dropLast())
        }
        let name = head.trimmingCharacters(in: .whitespaces)
        let text = visibility + generics(name) + "(" + generics(parameters) + ")"
            + (returnType.isEmpty ? "" : " : " + generics(returnType))
        return MermaidClassDiagram.Member(
            text: MermaidText.decoded(text),
            isStatic: classifier == "$",
            isAbstract: classifier == "*"
        )
    }

    /// `<<interface>>` as `interface`, when the line is one; `nil` otherwise.
    static func annotation(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 4, trimmed.hasPrefix("<<"), trimmed.hasSuffix(">>") else { return nil }
        return MermaidText.decoded(String(trimmed.dropFirst(2).dropLast(2)))
    }
}
