import Foundation

/// Narrowing a JSON tree to the values containing some text (2026-09-15).
///
/// The rules were the user's choice. A value matches when its key or its text contains the query,
/// ignoring case — the CSV table's filter's rule, and the pane's (`DelimitedTable.rowsMatching`) — and
/// a picker narrows it to keys or to values. Which rows a filtered tree then lists and opens is the
/// same for every tree (`TreeDocument`). The whole document is searched, not only what is open: it is
/// already in memory, so a match in a closed branch costs nothing to find, and one the reader cannot
/// see would read as none.
///
/// The query is read by `FilterQuery`, as the CSV filter's is. An ASCII query is matched against the
/// bytes in place with A–Z folded; a key or a string with an escape is decoded first, since its bytes
/// are not its text, and then folded the same way; and any other query decodes each text it reads.
extension JSONDocument {
    /// Which values contain `query`, ignoring case, in the keys, the values or both. Every value
    /// matches an empty query. `nil` when `isCancelled` answered `true`, which it is asked every
    /// thousand or so values.
    ///
    /// Blocking and linear in the document; call it off the main thread.
    public func filter(
        matching query: String,
        in scope: TreeFilterScope = .keysAndValues,
        isCancelled: () -> Bool = { false }
    ) -> TreeFilter? {
        let search = FilterQuery(query)
        return TreeFilter.build(count: nodes.count, parent: parent(of:), isCancelled: isCancelled) {
            search.isEmpty || matches(nodes[$0], scope: scope, search: search)
        }
    }

    // MARK: - Matching

    private func matches(_ node: Node, scope: TreeFilterScope, search: FilterQuery) -> Bool {
        if scope != .values, node.keyStart != Self.absent {
            let quote = Int(node.keyStart)
            if contains(
                search,
                from: quote + 1,
                to: closingQuote(after: quote),
                hasEscapes: node.flags & Node.keyHasEscapes != 0
            ) {
                return true
            }
        }
        guard scope != .keys else { return false }
        switch node.kind {
        case .object, .array:
            return false
        case .string:
            return contains(
                search,
                from: Int(node.valueStart) + 1,
                to: Int(node.valueEnd) - 1,
                hasEscapes: node.flags & Node.valueHasEscapes != 0
            )
        case .number, .boolean, .null:
            return contains(
                search,
                from: Int(node.valueStart),
                to: Int(node.valueEnd),
                hasEscapes: false
            )
        }
    }

    /// Whether the text in `bytes[start..<end]` contains the query, ignoring case. `hasEscapes` says
    /// the bytes are a string's between its quotes and need reading first.
    private func contains(_ search: FilterQuery, from start: Int, to end: Int, hasEscapes: Bool) -> Bool {
        if search.isASCII, !hasEscapes {
            return DelimitedTable.foldedContains(bytes, from: start, to: end, needle: search.bytes)
        }
        let text = hasEscapes
            ? decodeString(openingQuote: start - 1, closingQuote: end, hasEscapes: true)
            : Self.decodeUTF8(bytes[start..<end])
        return search.matches(text)
    }
}
