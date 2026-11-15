import Foundation

/// The accumulating state of one state-diagram parse (PLAN.md §M39 ▸ Slice 13).
///
/// A struct the parser mutates, as the flowchart's `Builder` is. It keeps a stack of open blocks —
/// the top level, then each `state X {` inside it — and every region any block opened, each knowing
/// the composite that owns it.
struct MermaidStateBuilder {
    private typealias Kind = MermaidStateDiagram.Kind

    private struct Record {
        let id: String
        var kind: Kind
        var descriptions: [String] = []
        /// The region the state is drawn in.
        var region: Int
        var regions: [Int] = []
        var direction: MermaidFlowchart.Direction?
        var notes: [MermaidStateDiagram.Note] = []
    }

    /// An open block: the composite it belongs to (`nil` at the top level) and the region its next
    /// statement lands in.
    private struct Block {
        let state: Int?
        var region: Int
    }

    private var records: [Record] = []
    private var ids: [String: Int] = [:]
    /// Each region's owner: a composite's index, or `nil` for the top level.
    private var regionOwners: [Int?] = [nil]
    private var rootRegions = [0]
    private var blocks = [Block(state: nil, region: 0)]
    /// Each region's start and end, made the first time a `[*]` needs one.
    private var starts: [Int: Int] = [:]
    private var ends: [Int: Int] = [:]
    private var transitions: [MermaidStateDiagram.Transition] = []
    private var direction = MermaidFlowchart.Direction.topDown
    private var undrawn: Set<String> = []

    // MARK: - Reading

    /// Reads the statement at `index`, and any it owns after it (a note's lines, a description
    /// block), and answers where the next one starts.
    mutating func read(_ statements: [String], at index: Int) -> Int {
        let statement = statements[index]
        let word = statement.prefix(while: { !$0.isWhitespace && $0 != ":" }).lowercased()
        switch word {
        case "}":
            if blocks.count > 1 { blocks.removeLast() }
        case "--" where statement.allSatisfy({ $0 == "-" }):
            splitRegion()
        case "direction":
            readDirection(statement)
        case "note":
            return readNote(statements, at: index)
        case "state":
            readState(String(statement.dropFirst(5)))
        case "classdef", "class", "style":
            undrawn.insert(word == "classdef" ? "classDef" : word)
        case "acctitle", "accdescr":
            // Accessibility text, which Mermaid does not draw either. A `{` opens a block of it
            // that runs to its `}`.
            guard statement.hasSuffix("{"), !statement.contains(":") else { return index + 1 }
            var next = index + 1
            while next < statements.count, statements[next] != "}" { next += 1 }
            return next + 1
        case "hide", "scale":
            // PlantUML's `hide empty description` and `scale`, which Mermaid reads and ignores.
            break
        default:
            readTransitionOrState(statement)
        }
        return index + 1
    }

    private mutating func readTransitionOrState(_ statement: String) {
        let colon = MermaidStateParser.separator(in: statement)
        guard let arrow = statement.range(of: "-->"),
              colon.map({ arrow.lowerBound < $0 }) ?? true
        else {
            // `id : description`, or a bare `id`.
            let id = MermaidStateParser.bareID(String(statement[..<(colon ?? statement.endIndex)]))
            guard !id.isEmpty, id != "[*]" else { return }
            let state = mention(id)
            if let colon, let text = MermaidStateParser.after(colon, in: statement) {
                records[state].descriptions.append(text)
            }
            return
        }
        let from = String(statement[..<arrow.lowerBound])
        let rest = String(statement[arrow.upperBound...])
        let labelAt = MermaidStateParser.separator(in: rest)
        let to = String(rest[..<(labelAt ?? rest.endIndex)])
        guard let source = endpoint(from, isSource: true),
              let target = endpoint(to, isSource: false)
        else { return }
        transitions.append(MermaidStateDiagram.Transition(
            from: source,
            to: target,
            label: labelAt.flatMap { MermaidStateParser.after($0, in: rest) }
        ))
    }

    /// `state "text" as id`, `state id`, either with a `<<choice>>` marker, a `: text`, or a `{`
    /// that opens the state's block.
    private mutating func readState(_ text: String) {
        var rest = text.trimmingCharacters(in: .whitespaces)
        let opens = rest.hasSuffix("{")
        if opens { rest = String(rest.dropLast()).trimmingCharacters(in: .whitespaces) }
        var description: String?
        // The quoted name first, so a `<<` inside it is part of the name and not a marker.
        if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
            description = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if rest.lowercased().hasPrefix("as ") { rest = String(rest.dropFirst(3)) }
        }
        let kind = MermaidStateParser.kind(marker: rest)
        if let marker = rest.range(of: "<<") ?? rest.range(of: "[[") {
            rest = String(rest[..<marker.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if description == nil, let colon = MermaidStateParser.separator(in: rest) {
            description = MermaidStateParser.after(colon, in: rest)
            rest = String(rest[..<colon])
        }
        let id = MermaidStateParser.bareID(rest)
        guard !id.isEmpty, id != "[*]" else { return }
        let state = mention(id)
        if let kind { records[state].kind = kind }
        if let description, !description.isEmpty { records[state].descriptions.append(description) }
        guard opens else { return }
        // A block written a second time for the same state carries on in its last region rather
        // than opening a parallel one, which a `--` is for.
        let region = records[state].regions.last ?? newRegion(of: state)
        blocks.append(Block(state: state, region: region))
    }

    /// `note left of X : text`, or `note right of X` with lines up to `end note`.
    private mutating func readNote(_ statements: [String], at index: Int) -> Int {
        let statement = statements[index]
        let words = statement.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard words.count >= 4, words[1] == "left" || words[1] == "right", words[2] == "of" else {
            if statement.contains("-->") {
                // A state that happens to be called `note`.
                readTransitionOrState(statement)
            } else {
                // `note "text" as N1`, a note on nothing, which this subset does not place.
                undrawn.insert("note")
            }
            return index + 1
        }
        let side: MermaidStateDiagram.NoteSide = words[1] == "left" ? .left : .right
        let target = statement.split(whereSeparator: \.isWhitespace).dropFirst(3).joined(
            separator: " "
        )
        let colon = MermaidStateParser.separator(in: target)
        let id = MermaidStateParser.bareID(String(target[..<(colon ?? target.endIndex)]))
        if let colon {
            if let text = MermaidStateParser.after(colon, in: target), !id.isEmpty {
                attach(MermaidStateDiagram.Note(side: side, lines: [text]), to: id)
            }
            return index + 1
        }
        var lines: [String] = []
        var next = index + 1
        while next < statements.count, statements[next].lowercased() != "end note" {
            lines.append(statements[next])
            next += 1
        }
        if !id.isEmpty, !lines.isEmpty {
            attach(MermaidStateDiagram.Note(side: side, lines: lines), to: id)
        }
        return next + 1
    }

    private mutating func readDirection(_ statement: String) {
        let word = statement.dropFirst("direction".count).trimmingCharacters(in: .whitespaces)
        guard let named = MermaidFlowchart.Direction.named(word) else { return }
        if let state = blocks[blocks.count - 1].state {
            records[state].direction = named
        } else {
            direction = named
        }
    }

    // MARK: - States and regions

    /// A transition's end: `[*]` is the current region's start or end, anything else a state.
    private mutating func endpoint(_ text: String, isSource: Bool) -> Int? {
        let id = MermaidStateParser.bareID(text)
        guard !id.isEmpty else { return nil }
        guard id == "[*]" else { return mention(id) }
        let region = blocks[blocks.count - 1].region
        if isSource, let start = starts[region] { return start }
        if !isSource, let end = ends[region] { return end }
        let state = records.count
        records.append(Record(
            id: "\u{0}\(isSource ? "start" : "end")\(region)",
            kind: isSource ? .start : .end,
            region: region
        ))
        if isSource { starts[region] = state } else { ends[region] = state }
        return state
    }

    /// The state called `id`, made in the current region if this is its first mention.
    ///
    /// A mention inside a composite's block moves a state there — the last block to mention it
    /// wins, and the top level never claims one back (`MermaidStateDiagram`). A move that would put
    /// a state inside itself is refused, so the blocks always form a tree however the file nests.
    private mutating func mention(_ id: String) -> Int {
        let region = blocks[blocks.count - 1].region
        guard let state = ids[id] else {
            ids[id] = records.count
            records.append(Record(id: id, kind: .state, region: region))
            return records.count - 1
        }
        if blocks.count > 1, records[state].region != region, !encloses(state, region: region) {
            records[state].region = region
        }
        return state
    }

    /// Whether `region` lies inside `state`, or is one of its own.
    private func encloses(_ state: Int, region: Int) -> Bool {
        var owner = regionOwners[region]
        var steps = 0
        while let current = owner, steps <= records.count {
            if current == state { return true }
            owner = regionOwners[records[current].region]
            steps += 1
        }
        return false
    }

    /// A note is about a state and does not move it, so only a state never mentioned before is made
    /// where the note stands.
    private mutating func attach(_ note: MermaidStateDiagram.Note, to id: String) {
        if let state = ids[id] {
            records[state].notes.append(note)
            return
        }
        ids[id] = records.count
        records.append(Record(id: id, kind: .state, region: blocks[blocks.count - 1].region))
        records[records.count - 1].notes.append(note)
    }

    private mutating func newRegion(of state: Int?) -> Int {
        let region = regionOwners.count
        regionOwners.append(state)
        if let state { records[state].regions.append(region) } else { rootRegions.append(region) }
        return region
    }

    /// `--`: the block it is in goes on in a new region beside the last.
    private mutating func splitRegion() {
        let block = blocks[blocks.count - 1]
        blocks[blocks.count - 1].region = newRegion(of: block.state)
    }

    // MARK: - The result

    var diagram: MermaidStateDiagram {
        var members = [[Int]](repeating: [], count: regionOwners.count)
        for (state, record) in records.enumerated() { members[record.region].append(state) }
        func regions(_ list: [Int]) -> [MermaidStateDiagram.Region] {
            list.filter { !members[$0].isEmpty }.map { MermaidStateDiagram.Region(
                states: members[$0]
            ) }
        }
        return MermaidStateDiagram(
            direction: direction,
            states: records.map { record in
                MermaidStateDiagram.State(
                    id: record.id,
                    kind: record.kind,
                    descriptions: record.descriptions,
                    regions: regions(record.regions),
                    direction: record.direction,
                    notes: record.notes
                )
            },
            regions: regions(rootRegions),
            transitions: transitions,
            undrawn: undrawn.sorted()
        )
    }
}
