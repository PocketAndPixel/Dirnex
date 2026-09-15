import Foundation

/// Which part of a value the JSON tree's filter reads (2026-09-15).
public enum JSONFilterScope: Int, Sendable, CaseIterable {
    /// A member's key, and a scalar's text.
    case keysAndValues
    case keys
    /// A string's text, or a number, `true`, `false` or `null` as written. A container has no text of
    /// its own to match.
    case values
}

/// What a filter over a `JSONDocument` found: which values matched, which lie on the way down to a
/// match, and which lie inside a matched container (2026-09-15).
///
/// One byte a value, answered in one pass (`JSONDocument.filter(matching:in:isCancelled:)`).
public struct JSONFilter: Sendable, Equatable {
    let flags: [UInt8]
    /// How many values matched.
    public let matchCount: Int

    static let matched: UInt8 = 1
    static let leadsToMatch: UInt8 = 2
    static let insideMatch: UInt8 = 4

    /// Whether the filter matched `value` itself: its key, or its text.
    public func isMatch(_ value: Int) -> Bool {
        flags[value] & Self.matched != 0
    }

    /// Whether a match lies somewhere inside `value` — the containers a filtered tree opens.
    public func leadsToMatch(_ value: Int) -> Bool {
        flags[value] & Self.leadsToMatch != 0
    }

    /// Whether a tree filtered this way shows `value`: a match, a container on the way down to one, or
    /// anything inside a matched container.
    public func isShown(_ value: Int) -> Bool {
        flags[value] != 0
    }

    /// Whether every child of `value` is shown — which is so inside a match, since a matched container
    /// keeps its contents.
    func showsAllChildren(of value: Int) -> Bool {
        flags[value] & (Self.matched | Self.insideMatch) != 0
    }
}

/// Narrowing a JSON tree to the values containing some text, and which rows such a tree lists and
/// opens (2026-09-15).
///
/// The rules were the user's choice. A value matches when its key or its text contains the query,
/// ignoring case — the CSV table's filter's rule, and the pane's (`DelimitedTable.rowsMatching`) — and
/// a picker narrows it to keys or to values. A match is shown with the way down to it, and a matched
/// object or array keeps everything inside it, closed, so that finding `compilerOptions` is finding
/// what it holds. The whole document is searched, not only what is open: it is already in memory, so
/// a match in a closed branch costs nothing to find, and one the reader cannot see would read as none.
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
        in scope: JSONFilterScope = .keysAndValues,
        isCancelled: () -> Bool = { false }
    ) -> JSONFilter? {
        let search = FilterQuery(query)
        var flags = [UInt8](repeating: 0, count: nodes.count)
        var matchCount = 0
        for value in nodes.indices {
            if value & 1023 == 0, isCancelled() { return nil }
            let node = nodes[value]
            if node.parent != Self.absent,
               flags[Int(node.parent)] & (JSONFilter.matched | JSONFilter.insideMatch) != 0 {
                flags[value] |= JSONFilter.insideMatch
            }
            guard search.isEmpty || matches(node, scope: scope, search: search) else { continue }
            flags[value] |= JSONFilter.matched
            matchCount += 1
            // Values are numbered in the order they start, so a parent always comes before its
            // children, and an ancestor already marked has had its own ancestors marked too.
            var ancestor = node.parent
            while ancestor != Self.absent, flags[Int(ancestor)] & JSONFilter.leadsToMatch == 0 {
                flags[Int(ancestor)] |= JSONFilter.leadsToMatch
                ancestor = nodes[Int(ancestor)].parent
            }
        }
        return JSONFilter(flags: flags, matchCount: matchCount)
    }

    /// The children of `value` a tree filtered by `filter` lists: all of them inside a match, and
    /// otherwise the ones it shows. All of them with no filter.
    public func children(of value: Int, filteredBy filter: JSONFilter?) -> [Int] {
        guard let filter, !filter.showsAllChildren(of: value) else { return children(of: value) }
        return children(of: value).filter(filter.isShown)
    }

    /// The values a tree filtered by `filter` lists at its top.
    public func topLevelValues(filteredBy filter: JSONFilter?) -> [Int] {
        guard let filter else { return topLevelValues }
        return topLevelValues.filter(filter.isShown)
    }

    // MARK: - Opening a tree

    /// The containers a tree opens as it is shown: level by level from the top, each container in the
    /// file's order opened while the rows then showing stay within `rowBudget`, and a container too big
    /// to fit left closed while its smaller siblings still open.
    ///
    /// So a `package.json` opens with everything in view, and a file whose top level holds one array of
    /// ten thousand entries opens with that array closed and the rest of the top level open. Filtered,
    /// only the containers on the way down to a match open — a matched container's own contents stay
    /// closed — and each opens to show only the children the filter leaves.
    public func initialExpansion(rowBudget: Int, filteredBy filter: JSONFilter? = nil) -> [Int] {
        let top = topLevelValues(filteredBy: filter)
        var rows = top.count
        var frontier = top.filter { canOpen($0, filteredBy: filter) }
        var expanded: [Int] = []
        while !frontier.isEmpty {
            var next: [Int] = []
            for container in frontier {
                let shown = children(of: container, filteredBy: filter)
                guard rows + shown.count <= rowBudget else { continue }
                rows += shown.count
                expanded.append(container)
                next += shown.filter { canOpen($0, filteredBy: filter) }
            }
            frontier = next
        }
        return expanded
    }

    private func canOpen(_ value: Int, filteredBy filter: JSONFilter?) -> Bool {
        guard kind(of: value).isContainer, childCount(of: value) > 0 else { return false }
        return filter.map { $0.leadsToMatch(value) } ?? true
    }

    // MARK: - Matching

    private func matches(_ node: Node, scope: JSONFilterScope, search: FilterQuery) -> Bool {
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
