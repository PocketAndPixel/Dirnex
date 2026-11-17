import Foundation

/// The accumulating state of one class-diagram parse (PLAN.md §M39 ▸ Slice 14).
///
/// Keeps the open blocks — each `namespace X {`, and at most one `class X {` inside them, whose
/// lines are members until its `}` — and the nodes in first-mention order.
struct MermaidClassBuilder {
    private typealias Diagram = MermaidClassDiagram

    private struct Record {
        let id: String
        let kind: Diagram.Kind
        /// A `class X["label"]`, which wins over anything else.
        var label: String?
        /// `X<T>`, from `X~T~` wherever it was written.
        var generic: String?
        var annotations: [String] = []
        var attributes: [Diagram.Member] = []
        var methods: [Diagram.Member] = []
        var lines: [String] = []
        var namespace: Int?
    }

    private var records: [Record] = []
    private var classes: [String: Int] = [:]
    private var namespaces: [Diagram.Namespace] = []
    private var namespaceIDs: [String: Int] = [:]
    private var openNamespaces: [Int] = []
    private var openClass: Int?
    private var relations: [Diagram.Relation] = []
    private var direction = MermaidFlowchart.Direction.topDown
    private var undrawn: Set<String> = []

    var diagram: MermaidClassDiagram {
        MermaidClassDiagram(
            direction: direction,
            nodes: records.map {
                Diagram.Node(
                    id: $0.id,
                    kind: $0.kind,
                    label: $0.label ?? $0.generic ?? $0.id,
                    annotations: $0.annotations,
                    attributes: $0.attributes,
                    methods: $0.methods,
                    lines: $0.lines,
                    namespace: $0.namespace
                )
            },
            namespaces: namespaces,
            relations: relations,
            undrawn: undrawn.sorted()
        )
    }

    // MARK: - Reading

    /// Reads the statement at `index`, and any block it owns, and answers where the next starts.
    mutating func read(_ statements: [String], at index: Int) -> Int {
        let statement = statements[index]
        if let open = openClass {
            readBody(statement, into: open)
            return index + 1
        }
        let word = statement.prefix { !$0.isWhitespace && $0 != ":" && $0 != "{" }.lowercased()
        switch word {
        case "}":
            _ = openNamespaces.popLast()
        case "direction":
            let name = statement.dropFirst(9).trimmingCharacters(in: .whitespaces)
            direction = MermaidFlowchart.Direction.named(name) ?? direction
        case "namespace":
            openNamespace(String(statement.dropFirst(9)))
            // A `{` alone on the next line opens the same block.
            return index + 1 < statements.count && statements[index + 1] == "{" ? index + 2 : index + 1
        case "class":
            readClass(statement.dropFirst(5))
        case "note":
            readNote(statement.dropFirst(4))
        case "click", "link", "callback", "style", "classdef", "cssclass":
            undrawn.insert(["classdef": "classDef", "cssclass": "cssClass"][word] ?? word)
        case "acctitle", "accdescr":
            // Accessibility text, which Mermaid does not draw either; a `{` opens a block of it.
            guard statement.hasSuffix("{"), !statement.contains(":") else { return index + 1 }
            var next = index + 1
            while next < statements.count, statements[next] != "}" { next += 1 }
            return next + 1
        default:
            if statement.hasPrefix("<<") {
                readAnnotation(statement)
            } else {
                readRelationOrMember(statement)
            }
        }
        return index + 1
    }

    /// A line inside `class X { … }`: an annotation, a member, or the `}` that closes it.
    private mutating func readBody(_ statement: String, into node: Int) {
        var line = Substring(statement)
        if line.hasSuffix("}") {
            openClass = nil
            line = line.dropLast()
        }
        addMember(String(line), to: node)
    }

    private mutating func addMember(_ raw: String, to node: Int) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        if let annotation = MermaidClassParser.annotation(line) {
            records[node].annotations.append(annotation)
        } else {
            let member = MermaidClassParser.member(line)
            // Mermaid's test is a `)` after the first character, made on the line as written.
            if line.dropFirst().contains(")") {
                records[node].methods.append(member)
            } else {
                records[node].attributes.append(member)
            }
        }
    }

    // MARK: - Classes

    /// `class X`, `class X~T~`, `class X["label"]`, `class X <<interface>>`, any of them opening a
    /// `{` block, which may close on the same line.
    private mutating func readClass(_ text: Substring) {
        let line = String(text)
        let brace = MermaidText.firstUnquoted("{", in: line)
        let head = brace.map { line[..<$0] } ?? Substring(line)
        guard let name = MermaidClassParser.name(at: head) else { return }
        var rest = name.rest.drop(while: \.isWhitespace)
        var label: String?
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            label = MermaidText.decoded(MermaidText.unquoted(String(rest.dropFirst()[..<close])))
            rest = rest[rest.index(after: close)...]
        }
        let node = mention(name.id, generic: name.generic)
        if let label, !label.isEmpty { records[node].label = label }
        if let open = rest.range(of: "<<"), let close = rest.range(of: ">>"),
           open.upperBound <= close.lowerBound {
            records[node].annotations.append(
                MermaidText.decoded(String(rest[open.upperBound..<close.lowerBound]))
            )
        }
        if let namespace = openNamespaces.last { records[node].namespace = namespace }
        guard let brace else { return }
        let body = line[line.index(after: brace)...]
        if let close = body.lastIndex(of: "}") {
            addMember(String(body[..<close]), to: node)
        } else {
            openClass = node
            addMember(String(body), to: node)
        }
    }

    /// `<<interface>> Shape`.
    private mutating func readAnnotation(_ statement: String) {
        guard let close = statement.range(of: ">>"),
              let name = MermaidClassParser.name(at: statement[close.upperBound...])
        else { return }
        let node = mention(name.id, generic: name.generic)
        records[node].annotations.append(
            MermaidText.decoded(
                String(
                    statement[statement.index(statement.startIndex, offsetBy: 2)..<close.lowerBound]
                )
            )
        )
    }

    /// `A <|-- B : label`, or `X : member`, or a bare `X`.
    private mutating func readRelationOrMember(_ statement: String) {
        let colon = MermaidClassRelationSyntax.colon(in: statement)
        let head = String(statement[..<(colon ?? statement.endIndex)])
        let after = colon.map { String(statement[statement.index(after: $0)...]) }
        guard let syntax = MermaidClassRelationSyntax.read(head) else {
            guard let name = MermaidClassParser.name(at: Substring(head)) else { return }
            let node = mention(name.id, generic: name.generic)
            if let after { addMember(after, to: node) }
            return
        }
        let from = endpoint(syntax.from, isInterface: syntax.fromEnd == .lollipop)
        let to = endpoint(syntax.to, isInterface: syntax.toEnd == .lollipop)
        let label = after.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        relations.append(Diagram.Relation(
            from: from,
            to: to,
            fromEnd: syntax.fromEnd,
            toEnd: syntax.toEnd,
            isDashed: syntax.isDashed,
            label: label.isEmpty ? nil : MermaidText.decoded(label),
            fromCardinality: syntax.fromCardinality,
            toCardinality: syntax.toCardinality
        ))
    }

    /// A relation's end: its class, or at a lollipop a new interface of that name, since each
    /// lollipop draws one of its own.
    private mutating func endpoint(_ name: (id: String, generic: String?), isInterface: Bool) -> Int {
        guard isInterface else { return mention(name.id, generic: name.generic) }
        records.append(Record(id: "interface\(records.count)", kind: .interface, label: name.id))
        return records.count - 1
    }

    /// The class with this id, made the first time it is mentioned.
    private mutating func mention(_ id: String, generic: String? = nil) -> Int {
        if let index = classes[id] {
            if records[index].generic == nil { records[index].generic = generic }
            return index
        }
        records.append(Record(id: id, kind: .class, generic: generic))
        classes[id] = records.count - 1
        return records.count - 1
    }

    // MARK: - Notes and namespaces

    /// `note for X "text"`, or a floating `note "text"`.
    private mutating func readNote(_ text: Substring) {
        var rest = text.drop(while: \.isWhitespace)
        var target: Int?
        if rest.lowercased().hasPrefix("for "), let name = MermaidClassParser.name(
            at: rest.dropFirst(4)
        ) {
            target = mention(name.id, generic: name.generic)
            rest = name.rest
        }
        let lines = MermaidText.lines(MermaidText.unquoted(String(rest))).map(MermaidText.decoded)
        records.append(Record(id: "note\(records.count)", kind: .note, lines: lines))
        guard let target else { return }
        relations.append(Diagram.Relation(
            from: records.count - 1,
            to: target,
            fromEnd: .none,
            toEnd: .none,
            isDashed: true,
            label: nil,
            fromCardinality: nil,
            toCardinality: nil,
            isNoteLink: true
        ))
    }

    /// `namespace A.B {` or `namespace A["Title"] {`, nested in any namespace already open. A dotted
    /// name is a chain of namespaces, each titled by its own part, shared with any other name that
    /// starts the same way.
    private mutating func openNamespace(_ text: String) {
        var line = text.trimmingCharacters(in: .whitespaces)
        if line.hasSuffix("{") { line = String(line.dropLast()).trimmingCharacters(in: .whitespaces) }
        var title: String?
        if let open = line.firstIndex(of: "["), line.hasSuffix("]") {
            title = MermaidText.decoded(
                MermaidText.unquoted(String(line[line.index(after: open)...].dropLast()))
            )
            line = String(line[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let parts = line.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        var parent = openNamespaces.last
        var id = parent.map { namespaces[$0].id } ?? ""
        for (position, part) in parts.enumerated() {
            id = id.isEmpty ? part : id + "." + part
            if let existing = namespaceIDs[id] {
                parent = existing
                continue
            }
            let isLeaf = position == parts.count - 1
            namespaces.append(Diagram.Namespace(
                id: id,
                title: isLeaf ? title ?? part : part,
                parent: parent,
                position: records.count
            ))
            namespaceIDs[id] = namespaces.count - 1
            parent = namespaces.count - 1
        }
        if let parent { openNamespaces.append(parent) }
    }
}
