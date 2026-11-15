import Foundation

/// An ER diagram's statements, read into entities, subgraphs and relationships (PLAN.md §M39 ▸
/// Slice 14).
///
/// One statement per line, no `;` separator, and entity blocks running from `NAME {` to `}`. Rules
/// that are Mermaid's rather than obvious are stated on `MermaidERDiagram`, and one more read off
/// it here: **an entity belongs to the first subgraph that mentions it**, and a later subgraph
/// naming it again draws empty, where a state diagram's last block wins (Mermaid 12.3).
enum MermaidERParser {
    static func parse(_ statements: [String]) -> MermaidERDiagram {
        var builder = MermaidERBuilder()
        for statement in statements { builder.read(statement) }
        return builder.diagram
    }

    typealias Cardinality = MermaidERDiagram.Cardinality

    /// One way of writing a cardinality or a line. A symbol may touch what follows; a word must end
    /// at a space.
    private struct Spelling<Value: Sendable>: Sendable {
        let text: String
        let value: Value
        let isWord: Bool

        init(_ text: String, _ value: Value, _ isWord: Bool) {
            self.text = text
            self.value = value
            self.isWord = isWord
        }
    }

    /// Every spelling of a cardinality, the longer first where one starts another (`1+` before
    /// `1`).
    private static let cardinalities: [Spelling<Cardinality>] = [
        Spelling("|o", .zeroOrOne, false), Spelling("o|", .zeroOrOne, false),
        Spelling("||", .exactlyOne, false),
        Spelling("}o", .zeroOrMore, false), Spelling("o{", .zeroOrMore, false),
        Spelling("}|", .oneOrMore, false), Spelling("|{", .oneOrMore, false),
        Spelling("one or zero", .zeroOrOne, true), Spelling("zero or one", .zeroOrOne, true),
        Spelling("one or more", .oneOrMore, true), Spelling("one or many", .oneOrMore, true),
        Spelling("many(1)", .oneOrMore, true), Spelling("1+", .oneOrMore, true),
        Spelling("zero or more", .zeroOrMore, true), Spelling("zero or many", .zeroOrMore, true),
        Spelling("many(0)", .zeroOrMore, true), Spelling("0+", .zeroOrMore, true),
        Spelling("only one", .exactlyOne, true), Spelling("1", .exactlyOne, true)
    ]

    /// Every spelling of a line, its value whether it identifies.
    private static let lines: [Spelling<Bool>] = [
        Spelling("--", true, false), Spelling("..", false, false),
        Spelling("optionally to", false, true), Spelling("to", true, true)
    ]

    struct Relationship {
        let from: String
        let to: String
        let fromCardinality: Cardinality
        let toCardinality: Cardinality
        let isIdentifying: Bool
    }

    /// `A ||--o{ B` or `A one to zero or more B`, the statement up to its label's colon.
    static func relationship(in head: String) -> Relationship? {
        guard let first = entityName(at: Substring(head)) else { return nil }
        var rest = first.rest.drop(while: \.isWhitespace)
        guard let left = match(cardinalities, in: &rest) else { return nil }
        rest = rest.drop(while: \.isWhitespace)
        guard let line = match(lines, in: &rest) else { return nil }
        rest = rest.drop(while: \.isWhitespace)
        guard let right = match(cardinalities, in: &rest),
              let second = entityName(at: rest)
        else { return nil }
        return Relationship(
            from: first.id,
            to: second.id,
            fromCardinality: left,
            toCardinality: right,
            isIdentifying: line
        )
    }

    /// The first spelling in `table` that `text` starts with, consumed; a word form only when a
    /// space follows it, so `1` is no prefix of an entity called `1st`.
    private static func match<Value>(
        _ table: [Spelling<Value>],
        in text: inout Substring
    ) -> Value? {
        let lowered = text.lowercased()
        for spelling in table where lowered.hasPrefix(spelling.text) {
            let after = text.dropFirst(spelling.text.count)
            if spelling.isWord, after.first.map({ !$0.isWhitespace }) ?? true { continue }
            text = after
            return spelling.value
        }
        return nil
    }

    /// An entity's name read off the start of a statement.
    struct Name {
        let id: String
        /// Its `[alias]`, when it has one.
        let alias: String?
        let rest: Substring
    }

    /// An entity's name at the start of `text`: `"quoted"`, or a run up to a space, a bracket or a
    /// brace, with its `[alias]` and any `:::class` after it.
    static func entityName(at text: Substring) -> Name? {
        var text = text.drop(while: \.isWhitespace)
        let id: String
        if text.hasPrefix("\"") {
            guard let close = text.dropFirst().firstIndex(of: "\"") else { return nil }
            id = String(text[text.index(after: text.startIndex)..<close])
            text = text[text.index(after: close)...]
        } else {
            let end = text.firstIndex { $0.isWhitespace || "[{\"".contains($0) || $0 == ":" } ?? text.endIndex
            id = String(text[..<end])
            text = text[end...]
        }
        guard !id.isEmpty else { return nil }
        var alias: String?
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            alias = MermaidText.unquoted(String(text.dropFirst()[..<close]))
            text = text[text.index(after: close)...]
        }
        if text.hasPrefix(":::") {
            text = text.dropFirst(3).drop { !$0.isWhitespace && $0 != "{" }
        }
        return Name(id: id, alias: alias, rest: text)
    }

    /// `type name [PK, FK] ["comment"]`. The type and the name are the first two words; keys are
    /// what sits between them and a quoted comment.
    static func attribute(_ line: String) -> MermaidERDiagram.Attribute? {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        var comment: String?
        if rest.hasSuffix("\""), let open = rest.dropLast().lastIndex(of: "\"") {
            comment = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            rest = rest[..<open]
        }
        let words = rest.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2 else { return nil }
        let keys = words.dropFirst(2)
            .joined(separator: " ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
        return MermaidERDiagram.Attribute(
            type: MermaidText.decoded(String(words[0])),
            name: MermaidText.decoded(String(words[1])),
            keys: keys.isEmpty ? nil : keys,
            comment: comment.map(MermaidText.decoded).flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// The accumulating state of one ER parse.
struct MermaidERBuilder {
    private typealias Diagram = MermaidERDiagram

    private struct Record {
        let id: String
        var alias: String?
        var attributes: [Diagram.Attribute] = []
        var group: Int?
    }

    private struct GroupRecord {
        let id: String
        let title: String
        let parent: Int?
        var direction: MermaidFlowchart.Direction?
        let position: Int
    }

    private var records: [Record] = []
    private var ids: [String: Int] = [:]
    private var groups: [GroupRecord] = []
    private var groupIDs: [String: Int] = [:]
    private var openGroups: [Int] = []
    private var openEntity: Int?
    private var relationships: [Diagram.Relationship] = []
    private var direction = MermaidFlowchart.Direction.topDown
    private var undrawn: Set<String> = []

    var diagram: MermaidERDiagram {
        MermaidERDiagram(
            direction: direction,
            entities: records.map {
                Diagram.Entity(
                    id: $0.id,
                    label: MermaidText.decoded($0.alias ?? $0.id),
                    attributes: $0.attributes,
                    group: $0.group
                )
            },
            groups: groups.map {
                Diagram.Group(
                    id: $0.id,
                    title: $0.title,
                    parent: $0.parent,
                    direction: $0.direction,
                    position: $0.position
                )
            },
            relationships: relationships,
            undrawn: undrawn.sorted()
        )
    }

    mutating func read(_ statement: String) {
        if let open = openEntity {
            var line = Substring(statement)
            if line.hasSuffix("}") {
                openEntity = nil
                line = line.dropLast()
            }
            if let attribute = MermaidERParser.attribute(String(line)) {
                records[open].attributes.append(attribute)
            }
            return
        }
        let word = statement.prefix { !$0.isWhitespace && !"{[:".contains($0) }.lowercased()
        switch word {
        case "end" where !openGroups.isEmpty:
            openGroups.removeLast()
        case "subgraph":
            openGroup(String(statement.dropFirst(8)))
        case "direction":
            let name = statement.dropFirst(9).trimmingCharacters(in: .whitespaces)
            guard let named = MermaidFlowchart.Direction.named(name) else { return }
            if let group = openGroups.last { groups[group].direction = named } else { direction = named }
        case "style", "classdef", "class":
            undrawn.insert(word == "classdef" ? "classDef" : word)
        case "acctitle", "accdescr":
            break
        default:
            readRelationshipOrEntity(statement)
        }
    }

    private mutating func readRelationshipOrEntity(_ statement: String) {
        let colon = MermaidClassRelationSyntax.colon(in: statement)
        let head = String(statement[..<(colon ?? statement.endIndex)])
        if let relationship = MermaidERParser.relationship(in: head) {
            let label = colon.map {
                MermaidText.unquoted(String(statement[statement.index(after: $0)...]))
            } ?? ""
            relationships.append(Diagram.Relationship(
                from: endpoint(relationship.from),
                to: endpoint(relationship.to),
                fromCardinality: relationship.fromCardinality,
                toCardinality: relationship.toCardinality,
                isIdentifying: relationship.isIdentifying,
                label: label.isEmpty ? nil : MermaidText.decoded(label)
            ))
            return
        }
        guard let name = MermaidERParser.entityName(at: Substring(statement)) else { return }
        let entity = mention(name.id)
        if let alias = name.alias, !alias.isEmpty { records[entity].alias = alias }
        let rest = name.rest.trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("{") else { return }
        let body = rest.dropFirst()
        if let close = body.lastIndex(of: "}") {
            if let attribute = MermaidERParser.attribute(String(body[..<close])) {
                records[entity].attributes.append(attribute)
            }
        } else {
            openEntity = entity
            if let attribute = MermaidERParser.attribute(String(body)) {
                records[entity].attributes.append(attribute)
            }
        }
    }

    /// A subgraph by its id, else an entity.
    private mutating func endpoint(_ name: String) -> Diagram.Endpoint {
        if let group = groupIDs[name] { return .group(group) }
        return .entity(mention(name))
    }

    /// The entity with this id, made the first time it is mentioned, and claimed by the subgraph
    /// open around it if no subgraph has claimed it yet.
    private mutating func mention(_ id: String) -> Int {
        let index: Int
        if let existing = ids[id] {
            index = existing
        } else {
            records.append(Record(id: id))
            index = records.count - 1
            ids[id] = index
        }
        if records[index].group == nil, let group = openGroups.last { records[index].group = group }
        return index
    }

    /// `subgraph id`, `subgraph "Quoted title"` or `subgraph id [title]`.
    private mutating func openGroup(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespaces)
        var id = line
        var title = line
        if line.hasPrefix("\"") {
            id = MermaidText.unquoted(line)
            title = id
        } else if let open = line.firstIndex(of: "["), line.hasSuffix("]") {
            id = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            title = MermaidText.unquoted(String(line[line.index(after: open)...].dropLast()))
        }
        guard !id.isEmpty else { return }
        groups.append(GroupRecord(
            id: id,
            title: MermaidText.decoded(title),
            parent: openGroups.last,
            direction: nil,
            position: records.count
        ))
        groupIDs[id] = groups.count - 1
        openGroups.append(groups.count - 1)
    }
}
