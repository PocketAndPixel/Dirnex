import Foundation

/// An XML file as Quick View's tree reads it, what its filter matches, and when it is a table
/// (2026-09-16).
///
/// The rows were the user's choice of two: every attribute a row of its own, `@name` and its value in
/// quotes, above the element's children — so each one can be selected, filtered to and copied, and has
/// a path of its own — while a closed element lists its attributes in its value column. An element
/// holding text and no element shows the text as its value.
extension XMLTree: TreeDocument {
    public var labelNoun: TreeLabelNoun { .name }

    public var valueCount: Int { nodes.count }

    /// The root element, with its name and attributes, rather than what it holds: unlike a JSON file's
    /// top level, the root has a name and attributes of its own worth a row.
    public var topLevelValues: [Int] { roots }

    /// An element holding elements opens as the tree is shown; an element whose only rows are its
    /// attributes does not, since its row already lists them.
    public func opensOnArrival(_ value: Int) -> Bool {
        kind(of: value) == .element && hasElementChildren(value)
    }

    public func keyLabel(of value: Int) -> TreeLabel {
        switch kind(of: value) {
        case .element:
            return .searched(name(of: value), role: .name)
        case .attribute:
            let text = "@" + name(of: value)
            return TreeLabel(
                text,
                role: .name,
                searched: text.index(after: text.startIndex)..<text.endIndex
            )
        case .text:
            return TreeLabel("#text", role: .annotation)
        }
    }

    /// An attribute's value in quotes; a text; an element's text, or when it holds no text its
    /// attributes; and for an element holding elements, its attributes or how many rows it holds,
    /// `‹3›`, with `…` when the read limit cut it.
    public func valueLabel(of value: Int) -> TreeLabel {
        let limit = TreeLabel.cellTextLimit
        switch kind(of: value) {
        case .attribute:
            return .quoted(attributeValue(of: value, byteLimit: limit))
        case .text:
            return .searched(trimmedText(of: value, byteLimit: limit), role: .text)
        case .element:
            let attributeCount = Int(nodes[value].attributeCount)
            if hasElementChildren(value) {
                if attributeCount > 0 {
                    return TreeLabel(attributeSummary(of: value), role: .annotation)
                }
                let count = childCount(of: value) - attributeCount
                return TreeLabel("‹\(count)\(isIncomplete(value) ? "…" : "")›", role: .annotation)
            }
            let text = trimmedText(of: value, byteLimit: limit)
            if text.isEmpty, attributeCount > 0 {
                return TreeLabel(attributeSummary(of: value), role: .annotation)
            }
            return .searched(text, role: .text)
        }
    }

    /// A value or a text as it reads, and an element as its source — unless it holds only text, when
    /// the text is what it says.
    public func stripText(of value: Int, byteLimit: Int) -> String {
        if let text = readableText(of: value, byteLimit: byteLimit) {
            return Self.cutForStrip(text, byteLimit: byteLimit)
        }
        return dedentedSource(of: value, byteLimit: byteLimit)
    }

    public func copiedText(of value: Int) -> String {
        readableText(of: value, byteLimit: .max) ?? dedentedSource(of: value)
    }

    /// An attribute's value, a text, or an element's text when it holds text and no element — or `nil`
    /// for an element that is better read as its source.
    private func readableText(of value: Int, byteLimit: Int) -> String? {
        // A little past the limit, so the strip can say it was cut.
        let reading = JSONDocument.saturatingSum(byteLimit, 1)
        switch kind(of: value) {
        case .attribute:
            return attributeValue(of: value, byteLimit: reading)
        case .text:
            return trimmedText(of: value, byteLimit: reading)
        case .element:
            guard !hasElementChildren(value) else { return nil }
            let text = trimmedText(of: value, byteLimit: reading)
            return text.isEmpty ? nil : text
        }
    }

    // MARK: - Filtering

    /// Which nodes contain `query`, ignoring case: an element's or attribute's name unless the picker
    /// says values, and an attribute's value, a text, or the text of an element holding no element
    /// unless it says names. An element holding elements has no text of its own to match.
    public func filter(
        matching query: String,
        in scope: TreeFilterScope = .keysAndValues,
        options: FilterQuery.Options = [],
        isCancelled: () -> Bool = { false }
    ) -> TreeFilter? {
        let search = FilterQuery(query, options: options)
        return TreeFilter.build(count: nodes.count, parent: parent(of:), isCancelled: isCancelled) {
            search.isEmpty || matches($0, scope: scope, search: search)
        }
    }

    private func matches(_ value: Int, scope: TreeFilterScope, search: FilterQuery) -> Bool {
        let entry = nodes[value]
        if scope != .values, entry.kind != .text,
           contains(search, from: Int(entry.nameStart), to: Int(entry.nameEnd)) {
            return true
        }
        guard scope != .keys else { return false }
        switch entry.kind {
        case .attribute:
            return entry.flags & Node.needsDecoding == 0
                ? contains(search, from: Int(entry.start), to: Int(entry.end))
                : search.matches(attributeValue(of: value))
        case .text:
            return entry.flags & Node.needsDecoding == 0
                ? contains(search, from: Int(entry.start), to: Int(entry.end))
                : search.matches(text(of: value))
        case .element:
            guard entry.flags & Node.hasElementChildren == 0 else { return false }
            return entry.flags & Node.contentHasMarkup == 0
                ? contains(search, from: Int(entry.contentStart), to: Int(entry.contentEnd))
                : search.matches(text(of: value))
        }
    }

    /// Whether `bytes[start..<end]`, which are their own text, contain the query.
    private func contains(_ search: FilterQuery, from start: Int, to end: Int) -> Bool {
        if search.isASCII {
            return search.matchesBytes(bytes, from: start, to: end)
        }
        return search.matches(JSONDocument.decodeUTF8(bytes[start..<end]))
    }

    // MARK: - Records

    /// The table the root's children make, when they are all one element: a row for each, a column
    /// for each attribute (`@name`) and each child element's name in the order they first appear, and
    /// `#text` for a child's own text — so `<Books>` of `<Book>` elements, and Android's
    /// `<resources>` of `<string name="…">` elements, read the way a CSV does. `nil` for a single child, children of more than one name, text at the root, or records
    /// with too little in common (`RecordTableBuilder.coverage`).
    ///
    /// An attribute's cell is its value, a child's is its text — or its attributes, when it holds no
    /// text — and a child holding elements is its source on one line. A record whose text sits beside
    /// elements is text with markup in it, and its `#text` is all of its content on one line: an
    /// Android string reads `Share with <xliff:g id="APP">%s</xliff:g>` rather than losing the sentence
    /// to a column holding `%s` (seen live, 2026-09-16). A name a record repeats takes the
    /// first element of that name: a record's repeated children are a list the cell cannot hold, and the
    /// first is what the record's own row reads first. A column is numeric when every cell in it that
    /// is not empty reads as a number. A record the read limit cut is left out.
    ///
    /// Blocking and linear in the nodes; call it off the main thread.
    public func recordTable(columnLimit: Int = 1024) -> DelimitedTable? {
        guard roots.count == 1, let root = roots.first, hasElementChildren(root) else { return nil }
        var records = content(of: root)
        guard let first = records.first, kind(of: first) == .element else { return nil }
        let recordName = Array(bytes[Int(nodes[first].nameStart)..<Int(nodes[first].nameEnd)])
        guard records.allSatisfy({ kind(of: $0) == .element && hasName($0, recordName) }) else {
            return nil
        }
        if let last = records.last, isIncomplete(last) { records.removeLast() }
        guard records.count >= 2 else { return nil }
        var members: [RecordTableBuilder.Member] = []
        for (row, record) in records.enumerated() {
            for attribute in attributes(of: record) {
                members.append(.init(row: row, title: "@" + name(of: attribute), value: attribute))
            }
            guard hasElementChildren(record) else {
                if !trimmedText(of: record, byteLimit: 1).isEmpty {
                    members.append(.init(row: row, title: "#text", value: record))
                }
                continue
            }
            guard !content(of: record).contains(where: { kind(of: $0) == .text }) else {
                members.append(.init(row: row, title: "#text", value: record))
                continue
            }
            var seen: Set<String> = []
            for child in content(of: record) where kind(of: child) == .element {
                let title = name(of: child)
                guard seen.insert(title).inserted else { continue }
                members.append(.init(row: row, title: title, value: child))
            }
        }
        return RecordTableBuilder.table(
            rowCount: records.count,
            members: members,
            columnLimit: columnLimit,
            appendCell: { appendCell(of: $0, to: &$1) },
            cellKind: { value in
                guard kind(of: value) == .attribute || !hasElementChildren(value) else { return .other }
                let text = cellText(of: value)
                if text.isEmpty { return .blank }
                return DelimitedTable.looksNumeric(text) ? .number : .other
            }
        )
    }

    /// A record's own cell is its content on one line; any other element holding elements is its
    /// source on one line.
    private func appendCell(of value: Int, to output: inout [UInt8]) {
        if kind(of: value) == .element, hasElementChildren(value) {
            if parent(of: value) != nil, parent(of: value) == roots.first {
                appendCompactContent(of: value, to: &output)
            } else {
                appendCompactSource(of: value, to: &output)
            }
        } else {
            output.append(contentsOf: cellText(of: value).utf8)
        }
    }

    /// An attribute's value, or the text of an element holding no element — its attributes when it
    /// holds no text either.
    private func cellText(of value: Int) -> String {
        guard kind(of: value) == .element else { return attributeValue(of: value) }
        let text = trimmedText(of: value)
        return text.isEmpty ? attributeSummary(of: value, byteLimit: .max) : text
    }
}

extension XMLTree {
    /// The tree a file of XML reads as: its keys and values when it is a property list, and otherwise
    /// its elements. `nil` when the text is not XML this reads.
    public static func document(from text: String, isTruncated: Bool = false) -> (any TreeDocument)? {
        guard let tree = parse(text, isTruncated: isTruncated) else { return nil }
        return PropertyListTree(tree) ?? tree
    }
}
