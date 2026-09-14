import Foundation

/// A field's place in the text a source view shows, and which column it belongs to — what colors the
/// columns of a delimited file shown as text.
///
/// Offsets are **UTF-16 code units**, as `SyntaxToken`'s are and for the same reason: they index an
/// `NSRange`, and handing back byte offsets would make the app walk the text again to convert them.
public struct DelimitedFieldSpan: Sendable, Equatable {
    public let offset: Int
    public let length: Int
    /// The field's position in its record, from 0.
    public let column: Int

    public init(offset: Int, length: Int, column: Int) {
        self.offset = offset
        self.length = length
        self.column = column
    }
}

/// What leaves a table: rows copied to the pasteboard, and the field spans a source view colors.
extension DelimitedTable {
    /// Data rows `rows` as tab-separated text, one line per row and every row `columnCount` values
    /// wide — what Numbers and Excel put on the pasteboard, so a paste into either lands in cells.
    ///
    /// A value holding a tab, a line break or a quote is quoted, with its quotes doubled, which is how
    /// both of them read one back. Rows outside the table are skipped.
    public func tabSeparatedText(rows: [Int]) -> String {
        rows.filter { $0 >= 0 && $0 < rowCount }
            .map { row in values(ofRow: row).map(Self.tabSeparatedField).joined(separator: "\t") }
            .joined(separator: "\n")
    }

    private static func tabSeparatedField(_ value: String) -> String {
        let needsQuotes = value.utf8.contains { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || $0 == 0x22 }
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Where each non-empty field sits in the text the table was read from, in order, header row
    /// included, stopping after `limit` spans.
    ///
    /// The span covers the field as written, quotes and all, since that is what a source view shows.
    /// The limit is the caller's cost bound: coloring is one attribute run per field, and a 4 MB file
    /// of short values is a million of them.
    public func fieldSpans(limit: Int = .max) -> [DelimitedFieldSpan] {
        var spans: [DelimitedFieldSpan] = []
        var bytePosition = 0
        var unitPosition = 0
        /// Advance the UTF-16 count to `target`, one byte at a time: a continuation byte adds nothing,
        /// the lead byte of a four-byte sequence adds a surrogate pair, every other byte adds one.
        func advance(to target: Int) {
            while bytePosition < target {
                let byte = bytes[bytePosition]
                if byte & 0xC0 != 0x80 {
                    unitPosition += byte >= 0xF0 ? 2 : 1
                }
                bytePosition += 1
            }
        }
        for record in 0..<recordCount {
            let first = recordStarts[record]
            for index in first..<recordStarts[record + 1] {
                let cell = cells[index]
                guard cell.end > cell.start else { continue }
                guard spans.count < limit else { return spans }
                advance(to: Int(cell.start))
                let offset = unitPosition
                advance(to: Int(cell.end))
                spans.append(DelimitedFieldSpan(
                    offset: offset,
                    length: unitPosition - offset,
                    column: index - first
                ))
            }
        }
        return spans
    }
}
