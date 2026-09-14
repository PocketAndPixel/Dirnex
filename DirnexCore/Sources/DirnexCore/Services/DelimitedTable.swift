import Foundation

/// A delimited-text file — CSV, TSV, and the semicolon and pipe files spreadsheets and scripts also
/// write — read into rows and columns for Quick View's table (2026-09-15).
///
/// It touches bytes, so per PLAN.md §2 it lives here and is tested; the app owns the `NSTableView`.
/// The decode is not repeated here: the caller hands in `TextPreview`'s text, so a CSV gets the same
/// BOM handling, encoding fallbacks, binary refusal and 4 MB ceiling as every other text file.
///
/// **Nothing is decoded up front.** The table keeps the file's UTF-8 bytes and, for every field, the
/// range it occupies (`DelimitedCell`); a cell becomes a `String` when it is shown. That keeps the
/// cost of a preview on the files that actually occur on this Mac — 18 800 rows of 7 columns, 3 MB —
/// to one pass over the bytes, rather than 130 000 string allocations for a view that draws a few
/// dozen rows.
///
/// The three things a file does not state about itself — which delimiter, whether the first row
/// names the columns, which columns hold numbers — are guessed from a sample, and the guesses live in
/// `DelimitedTable+Detection`.
public struct DelimitedTable: Sendable, Equatable {
    /// The four separators the detection chooses between.
    public enum Delimiter: String, Sendable, CaseIterable {
        case comma = ","
        /// What Excel writes in every locale whose decimal separator is a comma — Russian, German,
        /// French and most of Europe.
        case semicolon = ";"
        case tab = "\t"
        case pipe = "|"

        var byte: UInt8 {
            switch self {
            case .comma: 0x2C
            case .semicolon: 0x3B
            case .tab: 0x09
            case .pipe: 0x7C
            }
        }
    }

    public let delimiter: Delimiter
    /// Whether the first record names the columns rather than being data.
    public let hasHeaderRow: Bool
    /// The widest record's field count. A shorter record reads as empty in the columns it lacks.
    public let columnCount: Int
    /// For each column, whether every sampled non-empty data cell reads as a number — what the app
    /// right-aligns.
    public let numericColumns: [Bool]

    let bytes: [UInt8]
    let cells: [DelimitedCell]
    /// Index into `cells` where each record starts, plus one past the last. When `hasHeaderRow`,
    /// record 0 is the header and data row `n` is record `n + 1`.
    let recordStarts: [Int]

    /// How long an unclosed quote may run before the file is taken to be malformed rather than cut
    /// mid-field by a read limit. A quoted cell of more than this is a file where one stray quote has
    /// swallowed everything after it, and a table of that is less honest than the text.
    static let longestPlausibleOpenQuote = 64 * 1024

    // MARK: - Reading

    /// Read `text` as a table, or `nil` when it cannot honestly be shown as one.
    ///
    /// - Parameters:
    ///   - isTruncated: whether `text` stops at a read limit rather than at the file's end. The last
    ///     record is then incomplete unless it happened to end at a line break, and it is dropped
    ///     rather than shown with its last field cut short.
    ///   - delimiterHint: the delimiter the file's name implies (a `.tsv` says tab), which decides a
    ///     tie and is the answer when no delimiter fits at all.
    ///
    /// `nil` when there is no record, and when a quote never closes in a file that is not truncated —
    /// every field after it has run together, so the text is the truthful view.
    public static func parse(
        _ text: String,
        isTruncated: Bool = false,
        delimiterHint: Delimiter? = nil
    ) -> DelimitedTable? {
        let bytes = Array(text.utf8)
        guard bytes.count < Int(UInt32.max) else { return nil }
        let parsed = bytes.withUnsafeBufferPointer { buffer -> (
            Delimiter,
            DelimitedTextScanner.Result
        ) in
            let delimiter = detectDelimiter(in: buffer, hint: delimiterHint)
            return (delimiter, DelimitedTextScanner.scan(buffer, delimiter: delimiter.byte))
        }
        var scan = parsed.1
        if let open = scan.unterminatedQuoteLength {
            guard isTruncated, open <= longestPlausibleOpenQuote else { return nil }
            scan.dropLastRecord()
        } else if isTruncated, scan.endsMidRecord {
            scan.dropLastRecord()
        }
        guard scan.recordCount > 0 else { return nil }
        return DelimitedTable(bytes: bytes, delimiter: parsed.0, scan: scan)
    }

    private init(bytes: [UInt8], delimiter: Delimiter, scan: DelimitedTextScanner.Result) {
        self.bytes = bytes
        self.delimiter = delimiter
        cells = scan.cells
        recordStarts = scan.recordStarts
        var widest = 0
        for record in 0..<scan.recordCount {
            widest = max(widest, scan.fieldCount(ofRecord: record))
        }
        columnCount = widest
        let header = Self.guessHeaderRow(
            recordCount: scan.recordCount,
            fields: { record in Self.fields(ofRecord: record, bytes: bytes, scan: scan) }
        )
        hasHeaderRow = header
        numericColumns = Self.guessNumericColumns(
            columnCount: widest,
            firstDataRecord: header ? 1 : 0,
            recordCount: scan.recordCount,
            fields: { record in Self.fields(ofRecord: record, bytes: bytes, scan: scan) }
        )
    }

    // MARK: - Cells

    /// The number of data rows, the header row not counted.
    public var rowCount: Int { recordCount - (hasHeaderRow ? 1 : 0) }

    var recordCount: Int { recordStarts.count - 1 }

    /// The value in data row `row`, column `column` — empty for a column this row does not reach, and
    /// for any position outside the table.
    public func cell(row: Int, column: Int) -> String {
        let record = row + (hasHeaderRow ? 1 : 0)
        guard row >= 0, record < recordCount, column >= 0 else { return "" }
        let index = recordStarts[record] + column
        guard index < recordStarts[record + 1] else { return "" }
        return Self.value(of: cells[index], in: bytes)
    }

    /// Every value in data row `row`, padded with empty values to `columnCount`.
    public func values(ofRow row: Int) -> [String] {
        (0..<columnCount).map { cell(row: row, column: $0) }
    }

    /// What column `column` is called: the header row's text when there is one and it is not blank,
    /// and otherwise the column's spreadsheet letter.
    public func title(ofColumn column: Int) -> String {
        if hasHeaderRow, column >= 0, column < recordStarts[1] {
            let name = Self.value(of: cells[column], in: bytes)
            if !name.isEmpty { return name }
        }
        return Self.columnLetters(column)
    }

    /// A column's spreadsheet name — A to Z, then AA — for a file whose first row is data. Letters
    /// rather than "Column 1", because they need no translation and are what Numbers and Excel draw.
    public static func columnLetters(_ column: Int) -> String {
        var remaining = max(column, 0) + 1
        var letters: [Character] = []
        while remaining > 0 {
            let digit = (remaining - 1) % 26
            letters.append(Character(Unicode.Scalar(UInt8(0x41 + digit))))
            remaining = (remaining - 1) / 26
        }
        return String(letters.reversed())
    }

    /// A field's value: its bytes for an unquoted field, and for a quoted one the text inside with
    /// each doubled quote read as one.
    static func value(of cell: DelimitedCell, in bytes: [UInt8]) -> String {
        let start = Int(cell.start)
        let end = Int(cell.end)
        switch cell.form {
        case .verbatim:
            return decodeUTF8(bytes[start..<end])
        case .quoted:
            return decodeUTF8(bytes[(start + 1)..<(end - 1)])
        case .escaped:
            var value: [UInt8] = []
            value.reserveCapacity(end - start)
            var index = start + 1
            var isClosed = false
            while index < end {
                let byte = bytes[index]
                if !isClosed, byte == DelimitedTextScanner.quote {
                    if index + 1 < end, bytes[index + 1] == DelimitedTextScanner.quote {
                        value.append(byte)
                        index += 2
                        continue
                    }
                    isClosed = true
                    index += 1
                    continue
                }
                value.append(byte)
                index += 1
            }
            return decodeUTF8(value[...])
        }
    }

    /// The non-failing decode, and it is exact here rather than lossy: the bytes are a `String`'s own
    /// UTF-8, and every cut the scanner makes is at an ASCII byte, which is never inside a multi-byte
    /// sequence. A failable decode would be a `nil` no input can produce.
    private static func decodeUTF8(_ bytes: ArraySlice<UInt8>) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: bytes, as: UTF8.self)
    }

    /// Every value of one record, for the guesses made while the table is still being built.
    private static func fields(
        ofRecord record: Int,
        bytes: [UInt8],
        scan: DelimitedTextScanner.Result
    ) -> [String] {
        scan.cells[scan.recordStarts[record]..<scan.recordStarts[record + 1]]
            .map { value(of: $0, in: bytes) }
    }
}
