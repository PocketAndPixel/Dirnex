import Foundation

/// A property list as Quick View's tree reads it, what its filter matches, and when it is a table
/// (2026-09-16).
///
/// Drawn as the JSON tree is, which was what the user picked: a key and its value on one row, an
/// array's elements as `[0]`, a string in quotes, a number, date or data in the number color, `true`
/// and `false` as words, and a container as `{3}` or `[12]`. The path is the one `PlistBuddy` reads,
/// `:CFBundleURLTypes:0:CFBundleURLSchemes`, so it can be pasted into a command.
extension PropertyListTree: TreeDocument {
    public var labelNoun: TreeLabelNoun { .key }

    public var valueCount: Int { nodes.count }

    /// The root's own values when it is a container holding some, and otherwise the root.
    public var topLevelValues: [Int] {
        childCount(of: root) > 0 ? children(of: root) : [root]
    }

    public func opensOnArrival(_ value: Int) -> Bool {
        kind(of: value).isContainer
    }

    public func keyLabel(of value: Int) -> TreeLabel {
        if let key = key(of: value) {
            return key.isEmpty ? TreeLabel("\"\"", role: .annotation) : .searched(key, role: .name)
        }
        if parent(of: value) != nil {
            return TreeLabel("[\(position(of: value))]", role: .annotation)
        }
        return TreeLabel(":", role: .annotation)
    }

    public func valueLabel(of value: Int) -> TreeLabel {
        let kind = kind(of: value)
        switch kind {
        case .dictionary, .array:
            let cut = xml.isIncomplete(Int(nodes[value].element)) ? "…" : ""
            let count = "\(childCount(of: value))\(cut)"
            return TreeLabel(kind == .dictionary ? "{\(count)}" : "[\(count)]", role: .annotation)
        case .string:
            return .quoted(scalarText(of: value, byteLimit: TreeLabel.cellTextLimit))
        case .boolean:
            return .searched(scalarText(of: value), role: .keyword)
        case .integer, .real, .date, .data:
            return .searched(
                scalarText(of: value, byteLimit: TreeLabel.cellTextLimit),
                role: .number
            )
        }
    }

    /// Where `value` sits, as `PlistBuddy` names it: `:` and a key or an index for each level down.
    public func path(of value: Int) -> String {
        var segments: [String] = []
        var current = value
        while let parent = parent(of: current) {
            segments.append(key(of: current) ?? String(position(of: current)))
            current = parent
        }
        return ":" + segments.reversed().joined(separator: ":")
    }

    /// A scalar's text, and a container as the XML it is written in.
    public func stripText(of value: Int, byteLimit: Int) -> String {
        guard !kind(of: value).isContainer else {
            return xml.dedentedSource(of: Int(nodes[value].element), byteLimit: byteLimit)
        }
        let reading = JSONDocument.saturatingSum(byteLimit, 1)
        return Self.cutForStrip(scalarText(of: value, byteLimit: reading), byteLimit: byteLimit)
    }

    public func copiedText(of value: Int) -> String {
        kind(of: value).isContainer
            ? xml.dedentedSource(of: Int(nodes[value].element))
            : scalarText(of: value)
    }

    // MARK: - Filtering

    /// Which values contain `query`, ignoring case: a key unless the picker says values, and a scalar's
    /// text — as its row shows it — unless it says keys.
    public func filter(
        matching query: String,
        in scope: TreeFilterScope = .keysAndValues,
        isCancelled: () -> Bool = { false }
    ) -> TreeFilter? {
        let search = FilterQuery(query)
        return TreeFilter.build(count: nodes.count, parent: parent(of:), isCancelled: isCancelled) {
            search.isEmpty || matches($0, scope: scope, search: search)
        }
    }

    private func matches(_ value: Int, scope: TreeFilterScope, search: FilterQuery) -> Bool {
        let node = nodes[value]
        if scope != .values, node.key != XMLTree.absent,
           search.matches(xml.text(of: Int(node.key))) {
            return true
        }
        guard scope != .keys, !node.kind.isContainer else { return false }
        return search.matches(scalarText(of: value))
    }

    // MARK: - Records

    /// The table a property list whose root is an array of at least two dictionaries makes, a column
    /// for each key in the order keys first appear — the JSON rule. A scalar's cell is its text and a
    /// container's is its XML on one line; a column is numeric when every cell in it is an integer or a
    /// real. `nil` for anything else.
    public func recordTable(columnLimit: Int = 1024) -> DelimitedTable? {
        guard kind(of: root) == .array else { return nil }
        let records = children(of: root)
        guard records.count >= 2, records.allSatisfy({ kind(of: $0) == .dictionary }) else {
            return nil
        }
        var members: [RecordTableBuilder.Member] = []
        for (row, record) in records.enumerated() {
            for member in children(of: record) {
                members.append(.init(row: row, title: key(of: member) ?? "", value: member))
            }
        }
        return RecordTableBuilder.table(
            rowCount: records.count,
            members: members,
            columnLimit: columnLimit,
            appendCell: { value, output in
                if kind(of: value).isContainer {
                    xml.appendCompactSource(of: Int(nodes[value].element), to: &output)
                } else {
                    output.append(contentsOf: scalarText(of: value).utf8)
                }
            },
            cellKind: { value in
                kind(of: value) == .integer || kind(of: value) == .real ? .number : .other
            }
        )
    }
}
