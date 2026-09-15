import Foundation

/// A JSON file that is a list of like objects, as the rows of Quick View's table — and which of a
/// tree's containers are open as it is first shown (2026-09-15).
///
/// The shape was the user's choice: a tree for every JSON file, except a list of records, which reads
/// best the way a CSV does, a row a record and a column a key. Of the 1 487 JSON files in this Mac's
/// home folder that was 11 whose top level is an array of objects (`compile_commands.json`, chunks of
/// an API export) and 7 of the 8 JSON Lines files. A list one level down, `{"value": [...]}`, stays a
/// tree.
///
/// The table is a `DelimitedTable` built from the values rather than a type of its own, so the sorting,
/// the filter, ⌘C and the column sizing a CSV has come with it unchanged.
extension JSONDocument {
    /// How much of a table of records must be filled for it to be a table: the share of cells whose
    /// record has that key. Below it the objects are not alike — an event log of a dozen shapes — and a
    /// table of mostly blank cells says less than the tree.
    static let recordCoverage = 0.5

    /// The most cells a table of records is built with. The coverage already bounds a table to twice
    /// the members the file holds; this bounds what the check allocates before it can say so.
    static let recordCellLimit = 4_000_000

    /// The table this document's records make: one row for each object in a JSON Lines file or a
    /// top-level array, one column for each key in the order keys first appear, and the header row
    /// naming them. `nil` when the document is not a list of at least two objects, when the objects
    /// have too little in common (`recordCoverage`), or when they have more than `columnLimit` keys.
    ///
    /// A string's cell is its text, a nested value's is its compact JSON, and a number, `true`, `false`
    /// or `null` is as written. A key an object does not have is an empty cell; a key an object repeats
    /// takes the last value, as `JSON.parse` does. A column is numeric when every value in it that is
    /// not `null` is a number. A record the read limit cut is left out, as `DelimitedTable` leaves out
    /// a cut record.
    ///
    /// Blocking and linear in the members; call it off the main thread.
    public func recordTable(columnLimit: Int = 1024) -> DelimitedTable? {
        guard var records = recordValues else { return nil }
        if let last = records.last, isIncomplete(last) { records.removeLast() }
        guard records.count >= 2, records.allSatisfy({ kind(of: $0) == .object }) else { return nil }

        var titles: [String] = []
        var columns: [String: Int] = [:]
        var members: [RecordMember] = []
        for (row, record) in records.enumerated() {
            for member in children(of: record) {
                let key = key(of: member) ?? ""
                let column: Int
                if let known = columns[key] {
                    column = known
                } else {
                    guard titles.count < columnLimit else { return nil }
                    column = titles.count
                    columns[key] = column
                    titles.append(key)
                }
                members.append(RecordMember(row: row, column: column, value: member))
            }
        }
        let columnCount = titles.count
        guard columnCount > 0, records.count * columnCount <= Self.recordCellLimit else { return nil }
        var slots = [Int32](repeating: -1, count: records.count * columnCount)
        var filled = 0
        for member in members {
            let slot = member.row * columnCount + member.column
            if slots[slot] < 0 { filled += 1 }
            slots[slot] = Int32(member.value)
        }
        guard Double(filled) >= Self.recordCoverage * Double(slots.count) else { return nil }
        return buildTable(titles: titles, rowCount: records.count, slots: slots)
    }

    /// The values a table's rows would come from: the roots of a file of several, or the elements of
    /// a file that is one array.
    private var recordValues: [Int]? {
        if roots.count > 1 { return roots }
        guard let root = roots.first, kind(of: root) == .array else { return nil }
        return children(of: root)
    }

    private struct RecordMember {
        let row: Int
        let column: Int
        let value: Int
    }

    private func buildTable(titles: [String], rowCount: Int, slots: [Int32]) -> DelimitedTable? {
        let columnCount = titles.count
        var bytes: [UInt8] = []
        var cells: [DelimitedCell] = []
        cells.reserveCapacity(slots.count + columnCount)
        var recordStarts = [0]
        for title in titles {
            let start = UInt32(bytes.count)
            bytes.append(contentsOf: title.utf8)
            cells.append(DelimitedCell(start: start, end: UInt32(bytes.count), form: .verbatim))
        }
        recordStarts.append(cells.count)
        var sawNumber = [Bool](repeating: false, count: columnCount)
        var onlyNumbers = [Bool](repeating: true, count: columnCount)
        for row in 0..<rowCount {
            for column in 0..<columnCount {
                let start = bytes.count
                let value = Int(slots[row * columnCount + column])
                if value >= 0 {
                    appendText(of: value, to: &bytes)
                    switch kind(of: value) {
                    case .number: sawNumber[column] = true
                    case .null: break
                    default: onlyNumbers[column] = false
                    }
                }
                guard bytes.count < Int(Self.absent) else { return nil }
                cells.append(DelimitedCell(
                    start: UInt32(start),
                    end: UInt32(bytes.count),
                    form: .verbatim
                ))
            }
            recordStarts.append(cells.count)
        }
        return DelimitedTable(
            builtFrom: bytes,
            cells: cells,
            recordStarts: recordStarts,
            columnCount: columnCount,
            numericColumns: zip(sawNumber, onlyNumbers).map { $0 && $1 }
        )
    }

    // MARK: - Opening a tree

    /// The containers a tree opens as it is first shown: level by level from the top, each container in
    /// the file's order opened while the rows then showing stay within `rowBudget`, and a container too
    /// big to fit left closed while its smaller siblings still open.
    ///
    /// So a `package.json` opens with everything in view, and a file whose top level holds one array of
    /// ten thousand entries opens with that array closed and the rest of the top level open.
    public func initialExpansion(rowBudget: Int) -> [Int] {
        let top = topLevelValues
        var rows = top.count
        var frontier = top.filter(canOpen)
        var expanded: [Int] = []
        while !frontier.isEmpty {
            var next: [Int] = []
            for container in frontier {
                let added = childCount(of: container)
                guard rows + added <= rowBudget else { continue }
                rows += added
                expanded.append(container)
                next += children(of: container).filter(canOpen)
            }
            frontier = next
        }
        return expanded
    }

    private func canOpen(_ value: Int) -> Bool {
        kind(of: value).isContainer && childCount(of: value) > 0
    }
}
