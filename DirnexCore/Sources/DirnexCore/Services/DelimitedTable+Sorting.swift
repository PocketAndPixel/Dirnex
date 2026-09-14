import Foundation

/// The order a column puts a table's rows in — what clicking a column header in Quick View's table
/// does (2026-09-15).
///
/// The rules are a spreadsheet's rather than a string sort's, since a string sort of a column of
/// numbers is the one ordering nobody wants (`10` before `9`):
///
/// - A column whose sampled values are all numbers (`numericColumns`) sorts by value, reading `1,5`
///   and `1.5` the way the file writes them (`usesDecimalComma`). A value there that is not a number
///   after all — an `n/a` past the sample — sorts after every number.
/// - Any other column sorts the way Finder sorts names: `localizedStandardCompare`, so `file2` comes
///   before `file10` and case does not decide.
/// - An empty cell sorts last in both directions: blanks are what a reader scrolls past, not what the
///   table should open on.
/// - Rows that compare equal keep their order in the file, in both directions, so sorting by one
///   column and then another leaves the first one's order inside each group of the second.
extension DelimitedTable {
    /// Data row indices in the order column `column` sorts them, `ascending` or not. The file's own
    /// order for a column the table does not have.
    ///
    /// Blocking and linear in the rows plus a comparison sort over them; call it off the main thread.
    public func rowOrder(sortedByColumn column: Int, ascending: Bool) -> [Int] {
        let rows = Array(0..<rowCount)
        guard column >= 0, column < columnCount, rowCount > 1 else { return rows }
        let values = rows.map { cell(row: $0, column: column) }
        let keys: [SortKey]
        if numericColumns.indices.contains(column), numericColumns[column] {
            let decimalComma = Self.usesDecimalComma(values, delimiter: delimiter)
            keys = values.map { value in
                guard !value.isEmpty else { return .empty }
                return Self.numericValue(value, decimalComma: decimalComma).map(SortKey.number)
                    ?? .text(value)
            }
        } else {
            keys = values.map { $0.isEmpty ? .empty : .text($0) }
        }
        return rows.sorted { lhs, rhs in
            switch SortKey.order(keys[lhs], keys[rhs], ascending: ascending) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs < rhs
            }
        }
    }

    /// What a cell sorts as. The case order is the order the groups appear in, whichever the direction.
    enum SortKey {
        case number(Double)
        case text(String)
        case empty

        private var group: Int {
            switch self {
            case .number: 0
            case .text: 1
            case .empty: 2
            }
        }

        /// Groups in their fixed order; within a group, by value in the direction asked for.
        static func order(_ lhs: SortKey, _ rhs: SortKey, ascending: Bool) -> ComparisonResult {
            guard lhs.group == rhs.group else {
                return lhs.group < rhs.group ? .orderedAscending : .orderedDescending
            }
            let result: ComparisonResult = switch (lhs, rhs) {
            case let (.number(left), .number(right)):
                left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
            case let (.text(left), .text(right)):
                left.localizedStandardCompare(right)
            default:
                .orderedSame
            }
            guard !ascending else { return result }
            switch result {
            case .orderedAscending: return .orderedDescending
            case .orderedDescending: return .orderedAscending
            case .orderedSame: return .orderedSame
            }
        }
    }

    /// Whether a numeric column writes its decimals with a comma — `1,5` — rather than a point.
    ///
    /// The first value that settles it decides: a value with both separators uses the later one for
    /// decimals (`1.234,56`, `1,234.56`); a lone separator followed by anything but three digits is a
    /// decimal (`1,5`, `2.25`), and a separator that repeats groups thousands (`1,234,567`). Only
    /// `1,234` or `1.234` alone cannot say, and a column of nothing else is read by the delimiter: a
    /// semicolon file is what a locale with decimal commas writes.
    static func usesDecimalComma(_ values: [String], delimiter: Delimiter) -> Bool {
        for value in values where !value.isEmpty {
            let units = Array(value.utf8)
            let commas = units.indices.filter { units[$0] == 0x2C }
            let points = units.indices.filter { units[$0] == 0x2E }
            if let comma = commas.last, let point = points.last {
                return comma > point
            }
            if let comma = commas.last {
                if commas.count > 1 { return false }
                if digits(after: comma, in: units) != 3 { return true }
            } else if let point = points.last {
                if points.count > 1 { return true }
                if digits(after: point, in: units) != 3 { return false }
            }
        }
        return delimiter == .semicolon
    }

    private static func digits(after index: Int, in units: [UInt8]) -> Int {
        var count = 0
        var position = index + 1
        while position < units.count, units[position] >= 0x30, units[position] <= 0x39 {
            count += 1
            position += 1
        }
        return count
    }

    /// The number `value` writes, with grouping separators dropped and the decimal one read as a
    /// point. `nil` for anything `looksNumeric` refuses.
    static func numericValue(_ value: String, decimalComma: Bool) -> Double? {
        guard looksNumeric(value) else { return nil }
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix("%") { text.removeLast() }
        if decimalComma {
            text = text.replacingOccurrences(of: ".", with: "").replacingOccurrences(
                of: ",",
                with: "."
            )
        } else {
            text = text.replacingOccurrences(of: ",", with: "")
        }
        if text.hasPrefix(".") || text.hasPrefix("-.") || text.hasPrefix("+.") {
            text = text.replacingOccurrences(
                of: ".",
                with: "0.",
                options: [],
                range: text.range(of: ".")
            )
        }
        return Double(text)
    }
}
