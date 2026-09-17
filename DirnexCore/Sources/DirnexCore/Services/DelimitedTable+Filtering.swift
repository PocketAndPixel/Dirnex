import Foundation

/// Which rows a filter keeps — what typing into Quick View's table filter does (2026-09-15).
///
/// A row is kept when one of its cells contains the text, in any column or in one chosen column.
/// Case does not count and accents do: it is the pane's own filter's rule (`DirectoryModel.filter`),
/// so one box does not mean two things in one app. Ignoring accents as well was measured and turned
/// down: it read `й` as `и`, which are different letters in Russian, and it cost 490 ms against
/// 140 ms for a text found nowhere in a million cells.
///
/// Only the data rows are searched. The header names the columns, and the column picker is how a
/// column is chosen.
///
/// For text that is all ASCII — the ordinary case, and the one a keystroke meets most — nothing is
/// decoded: each cell's bytes are compared in place with `A`–`Z` folded, the fast path the pane's
/// filter takes. An ASCII byte never occurs inside a multi-byte character, so the fold cannot make a
/// match of a non-ASCII byte. Other text decodes the cells it reads.
extension DelimitedTable {
    /// For each data row, whether a cell contains `query` ignoring case: any cell, or the one in
    /// `column` when it is given. Every row for an empty `query`; none for a column the table does
    /// not have. `nil` when `isCancelled` answered `true`, which it is asked every thousand or so rows.
    ///
    /// Blocking and linear in the cells it reads; call it off the main thread.
    public func rowsMatching(
        _ query: String,
        inColumn column: Int? = nil,
        options: FilterQuery.Options = [],
        isCancelled: () -> Bool = { false }
    ) -> [Bool]? {
        let search = FilterQuery(query, options: options)
        guard !search.isEmpty else { return [Bool](repeating: true, count: rowCount) }
        let columns: Range<Int> = if let column {
            column >= 0 && column < columnCount ? column..<(column + 1) : 0..<0
        } else {
            0..<columnCount
        }
        var matches = [Bool](repeating: false, count: rowCount)
        guard !columns.isEmpty else { return matches }
        let firstRecord = hasHeaderRow ? 1 : 0
        for row in 0..<rowCount {
            if row & 1023 == 0, isCancelled() { return nil }
            let start = recordStarts[row + firstRecord]
            // A row shorter than the table reaches fewer columns, and may not reach the one searched.
            let reached = min(columns.upperBound, recordStarts[row + firstRecord + 1] - start)
            guard reached > columns.lowerBound else { continue }
            for column in columns.lowerBound..<reached {
                let cell = cells[start + column]
                let found = search.isASCII
                    ? self.cell(cell, contains: search)
                    : search.matches(Self.value(of: cell, in: bytes))
                if found {
                    matches[row] = true
                    break
                }
            }
        }
        return matches
    }

    /// Whether `cell`'s value contains `search`, an ASCII query, read in place under whatever options
    /// it carries. A plain or plainly quoted value is its bytes, so they are read where they lie; one
    /// with a doubled quote or text after its closing quote is decoded first, since its bytes are not
    /// its value.
    ///
    /// The bounds handed over are the *value's*, which is what makes a whole-word search right at a
    /// cell's edges: the comma and the quotes around a value are not part of it, so a cell holding
    /// exactly the query is a whole word rather than one wedged between punctuation.
    private func cell(_ cell: DelimitedCell, contains search: FilterQuery) -> Bool {
        switch cell.form {
        case .verbatim:
            search.matchesBytes(bytes, from: Int(cell.start), to: Int(cell.end))
        case .quoted:
            search.matchesBytes(bytes, from: Int(cell.start) + 1, to: Int(cell.end) - 1)
        case .escaped:
            search.matchesBytes(Array(Self.value(of: cell, in: bytes).utf8), from: 0, to: Int.max)
        }
    }

    /// `byte` with `A`–`Z` read as `a`–`z` — the whole of an ASCII query's case rule (`FilterQuery`).
    @inline(__always)
    static func folded(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }
}
