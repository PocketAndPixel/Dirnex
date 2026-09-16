import Foundation

/// A JSON file that is a list of like objects, as the rows of Quick View's table (2026-09-15).
///
/// The shape was the user's choice: a tree for every JSON file, except a list of records, which reads
/// best the way a CSV does, a row a record and a column a key. Of the 1 487 JSON files in this Mac's
/// home folder that was 11 whose top level is an array of objects (`compile_commands.json`, chunks of
/// an API export) and 7 of the 8 JSON Lines files. A list one level down, `{"value": [...]}`, stays a
/// tree.
///
/// The table is a `DelimitedTable` built from the values rather than a type of its own
/// (`RecordTableBuilder`), so the sorting, the filter, ⌘C and the column sizing a CSV has come with it
/// unchanged.
extension JSONDocument {
    /// The table this document's records make: one row for each object in a JSON Lines file or a
    /// top-level array, one column for each key in the order keys first appear, and the header row
    /// naming them. `nil` when the document is not a list of at least two objects, when the objects
    /// have too little in common (`RecordTableBuilder.coverage`), or when they have more than
    /// `columnLimit` keys.
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
            appendCell: { appendText(of: $0, to: &$1) },
            cellKind: { value in
                switch kind(of: value) {
                case .number: .number
                case .null: .blank
                default: .other
                }
            }
        )
    }

    /// The values a table's rows would come from: the roots of a file of several, or the elements of
    /// a file that is one array.
    private var recordValues: [Int]? {
        if roots.count > 1 { return roots }
        guard let root = roots.first, kind(of: root) == .array else { return nil }
        return children(of: root)
    }
}
