import Foundation

/// A file Quick View draws as a tree of rows — JSON, XML, a property list — as the one tree view reads
/// it (2026-09-16).
///
/// Split out of `JSONDocument` when XML became the second file drawn as a tree, so the outline view,
/// its strip, its filter and its zoom stay one implementation rather than one per format. A value is an
/// `Int`, numbered in the order the value starts in the file, so a parent always comes before its
/// children — the order `TreeFilter` is built in one pass on.
///
/// Every requirement answers for the rows a tree **lists**, which is not always everything the file
/// holds: an XML element's own text is its value rather than a row of its own.
public protocol TreeDocument: Sendable {
    /// What the first column names.
    var labelNoun: TreeLabelNoun { get }
    /// How many values the document holds, at every depth — what a filter's count is out of.
    var valueCount: Int { get }
    /// The values a tree lists at its top.
    var topLevelValues: [Int] { get }
    /// Whether the text stops at a read limit rather than at the file's end.
    var isTruncated: Bool { get }

    /// How many rows the tree lists under `value`. 0 for a value with no disclosure triangle.
    func childCount(of value: Int) -> Int
    /// The `index`th row under `value`.
    func child(_ index: Int, of value: Int) -> Int
    /// Every row under `value`, in order.
    func children(of value: Int) -> [Int]
    /// The value `value` is listed under, or `nil` for a value at the top.
    func parent(of value: Int) -> Int?
    /// Whether an unfiltered tree opens `value` as it is first shown, room allowing. A JSON container
    /// does; an XML element whose only rows are its attributes does not, since its row already lists
    /// them.
    func opensOnArrival(_ value: Int) -> Bool

    /// The first column's text for `value`.
    func keyLabel(of value: Int) -> TreeLabel
    /// The second column's text for `value`, cut to about `TreeLabel.cellTextLimit`.
    func valueLabel(of value: Int) -> TreeLabel
    /// Where `value` sits, in the format's own path syntax.
    func path(of value: Int) -> String
    /// What the strip under the tree shows as `value`'s text, cut after `byteLimit` UTF-8 bytes with
    /// `…` after the cut.
    func stripText(of value: Int, byteLimit: Int) -> String
    /// What ⌘C copies for `value`: all of it.
    func copiedText(of value: Int) -> String

    /// Which values contain `query`, ignoring case, in the first column, the second or both. `nil` when
    /// `isCancelled` answered `true`. Blocking and linear in the document; call it off the main thread.
    func filter(
        matching query: String,
        in scope: TreeFilterScope,
        isCancelled: () -> Bool
    ) -> TreeFilter?

    /// The document's records as a table, when it is a list of like records, or `nil`. Blocking; call
    /// it off the main thread.
    func recordTable(columnLimit: Int) -> DelimitedTable?
}

/// What a tree's first column names: a key a value is stored under (JSON, a property list), or an
/// element's or attribute's name (XML). The app words the column and the filter's picker by it.
public enum TreeLabelNoun: Sendable {
    case key
    case name
}

/// One cell's text, what kind of text it is, and which part of it a filter reads (2026-09-16).
///
/// The kind rather than a color, since colors are the app's; it maps each to the source view's.
public struct TreeLabel: Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        /// A key or a name.
        case name
        /// Something the tree says about a value rather than the file: an index, a count, `#text`.
        case annotation
        /// A string, quoted.
        case string
        /// Text as a document holds it, unquoted: an XML element's content.
        case text
        case number
        /// `true`, `false` or `null`.
        case keyword
    }

    public let text: String
    public let role: Role
    /// The part of `text` a filter reads, where a match is marked, or `nil` for none of it: a string
    /// inside its quotes, and never an index or a count.
    public let searched: Range<String.Index>?

    public init(_ text: String, role: Role, searched: Range<String.Index>? = nil) {
        self.text = text
        self.role = role
        self.searched = searched
    }

    /// A label whose whole text the filter reads.
    public static func searched(_ text: String, role: Role) -> TreeLabel {
        TreeLabel(text, role: role, searched: text.startIndex..<text.endIndex)
    }

    /// `text` in quotes, the filter reading inside them.
    public static func quoted(_ text: String) -> TreeLabel {
        let quoted = "\"\(text)\""
        return TreeLabel(
            quoted,
            role: .string,
            searched: quoted.index(after: quoted.startIndex)..<quoted.index(before: quoted.endIndex)
        )
    }

    /// The most of a value a cell decodes, which is already wider than any column.
    public static let cellTextLimit = 512
}

/// Which part of a value a tree's filter reads (2026-09-15).
public enum TreeFilterScope: Int, Sendable, CaseIterable {
    /// The first column and the second.
    case keysAndValues
    /// A member's key, or an element's or attribute's name.
    case keys
    /// A scalar's text. A container has no text of its own to match.
    case values
}

/// What a filter over a tree found: which values matched, which lie on the way down to a match, and
/// which lie inside a matched container (2026-09-15).
///
/// One byte a value, answered in one pass (`TreeFilter.build`).
public struct TreeFilter: Sendable, Equatable {
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

    /// The one pass every format's filter is: a value under a matched container is inside it, and a
    /// match marks its parents until it meets one already marked. `parent` answers the value a value
    /// is listed under, and values must be numbered so that a parent comes before its children.
    /// `matches` is asked for every value; `isCancelled` every 1,024. Every value matches an empty
    /// query, which the caller decides by what it passes as `matches`.
    static func build(
        count: Int,
        parent: (Int) -> Int?,
        isCancelled: () -> Bool,
        matches: (Int) -> Bool
    ) -> TreeFilter? {
        var flags = [UInt8](repeating: 0, count: count)
        var matchCount = 0
        for value in 0..<count {
            if value & 1023 == 0, isCancelled() { return nil }
            let up = parent(value)
            if let up, flags[up] & (matched | insideMatch) != 0 {
                flags[value] |= insideMatch
            }
            guard matches(value) else { continue }
            flags[value] |= matched
            matchCount += 1
            // A parent always comes before its children, so an ancestor already marked has had its
            // own ancestors marked too.
            var ancestor = up
            while let current = ancestor, flags[current] & leadsToMatch == 0 {
                flags[current] |= leadsToMatch
                ancestor = parent(current)
            }
        }
        return TreeFilter(flags: flags, matchCount: matchCount)
    }
}

/// Which rows a filtered tree lists and opens, the same for every format (2026-09-15).
///
/// The rules were the user's choice for the JSON tree, and XML keeps them. A match is shown with the
/// way down to it, and a matched container keeps everything inside it, closed, so that finding
/// `compilerOptions` is finding what it holds. The whole document is searched, not only what is open.
extension TreeDocument {
    public func children(of value: Int) -> [Int] {
        (0..<childCount(of: value)).map { child($0, of: value) }
    }

    public func opensOnArrival(_ value: Int) -> Bool {
        true
    }

    /// The children of `value` a tree filtered by `filter` lists: all of them inside a match, and
    /// otherwise the ones it shows. All of them with no filter.
    public func children(of value: Int, filteredBy filter: TreeFilter?) -> [Int] {
        guard let filter, !filter.showsAllChildren(of: value) else { return children(of: value) }
        return children(of: value).filter(filter.isShown)
    }

    /// The values a tree filtered by `filter` lists at its top.
    public func topLevelValues(filteredBy filter: TreeFilter?) -> [Int] {
        guard let filter else { return topLevelValues }
        return topLevelValues.filter(filter.isShown)
    }

    /// The containers a tree opens as it is shown: level by level from the top, each container in the
    /// file's order opened while the rows then showing stay within `rowBudget`, and a container too big
    /// to fit left closed while its smaller siblings still open.
    ///
    /// So a `package.json` opens with everything in view, and a file whose top level holds one array of
    /// ten thousand entries opens with that array closed and the rest of the top level open. Filtered,
    /// only the containers on the way down to a match open — a matched container's own contents stay
    /// closed — and each opens to show only the children the filter leaves.
    public func initialExpansion(rowBudget: Int, filteredBy filter: TreeFilter? = nil) -> [Int] {
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

    private func canOpen(_ value: Int, filteredBy filter: TreeFilter?) -> Bool {
        guard childCount(of: value) > 0 else { return false }
        return filter.map { $0.leadsToMatch(value) } ?? opensOnArrival(value)
    }
}

extension TreeDocument {
    /// `text` cut after `byteLimit` UTF-8 bytes at a whole character, with `…` after a cut.
    static func cutForStrip(_ text: String, byteLimit: Int) -> String {
        guard text.utf8.count > byteLimit else { return text }
        var bytes = Array(text.utf8.prefix(byteLimit))
        JSONDocument.cut(&bytes, toBytes: byteLimit)
        return JSONDocument.decodeUTF8(bytes) + "…"
    }
}
