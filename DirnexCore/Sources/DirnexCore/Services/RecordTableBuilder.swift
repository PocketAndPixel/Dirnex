import Foundation

/// A list of like records — JSON objects, XML elements, property-list dictionaries — made into the
/// `DelimitedTable` a CSV is drawn in, so the sorting, the filter, ⌘C and the column sizing come with
/// it unchanged (2026-09-15; shared from 2026-09-16, when XML became the second format drawn so).
///
/// A column for each field name in the order names first appear, a row for each record, and a table
/// only when the records have enough in common: at least half the cells filled (`coverage`).
struct RecordTableBuilder {
    /// One field of one record: the row, the column's title, and the value its cell shows.
    struct Member {
        let row: Int
        let title: String
        let value: Int
    }

    /// What a cell says about its column being numeric.
    enum CellKind {
        case number
        /// Nothing written, or `null`, which leaves a column's kind to its other cells.
        case blank
        case other
    }

    /// How much of a table must be filled for it to be a table: the share of cells whose record has
    /// that field. Below it the records are not alike — an event log of a dozen shapes — and a table of
    /// mostly blank cells says less than the tree.
    static let coverage = 0.5

    /// The most cells a table is built with. The coverage already bounds a table to twice the members
    /// the file holds; this bounds what the check allocates before it can say so.
    static let cellLimit = 4_000_000

    /// The table `members` make, or `nil` when there are more than `columnLimit` titles, too many
    /// cells, or too few of them filled. A title a record repeats keeps the last value it is given.
    /// A column is numeric when every cell in it that is not blank is a number, and one is.
    static func table(
        rowCount: Int,
        members: [Member],
        columnLimit: Int,
        appendCell: (Int, inout [UInt8]) -> Void,
        cellKind: (Int) -> CellKind
    ) -> DelimitedTable? {
        var titles: [String] = []
        var columns: [String: Int] = [:]
        var memberColumns: [Int] = []
        memberColumns.reserveCapacity(members.count)
        for member in members {
            let column: Int
            if let known = columns[member.title] {
                column = known
            } else {
                guard titles.count < columnLimit else { return nil }
                column = titles.count
                columns[member.title] = column
                titles.append(member.title)
            }
            memberColumns.append(column)
        }
        let columnCount = titles.count
        guard columnCount > 0, rowCount * columnCount <= cellLimit else { return nil }
        var slots = [Int32](repeating: -1, count: rowCount * columnCount)
        var filled = 0
        for (member, column) in zip(members, memberColumns) {
            let slot = member.row * columnCount + column
            if slots[slot] < 0 { filled += 1 }
            slots[slot] = Int32(member.value)
        }
        guard Double(filled) >= coverage * Double(slots.count) else { return nil }
        return build(
            titles: titles,
            rowCount: rowCount,
            slots: slots,
            appendCell: appendCell,
            cellKind: cellKind
        )
    }

    private static func build(
        titles: [String],
        rowCount: Int,
        slots: [Int32],
        appendCell: (Int, inout [UInt8]) -> Void,
        cellKind: (Int) -> CellKind
    ) -> DelimitedTable? {
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
                    appendCell(value, &bytes)
                    switch cellKind(value) {
                    case .number: sawNumber[column] = true
                    case .blank: break
                    case .other: onlyNumbers[column] = false
                    }
                }
                guard bytes.count < Int(UInt32.max) else { return nil }
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
}
