import Foundation

/// Where one field of a delimited-text record sits in the file's UTF-8 bytes, and how to read it.
///
/// A range rather than a decoded `String`, because a 4 MB CSV of short values is a million fields and
/// the table shows perhaps sixty of them at a time. Scanning costs one pass over the bytes and 12
/// bytes a field; a field becomes a `String` only when something asks to see it
/// (`DelimitedTable.value(of:)`).
struct DelimitedCell: Sendable, Equatable {
    /// How the bytes in `start..<end` become the field's value.
    enum Form: UInt8, Sendable {
        /// Exactly the bytes: the field was not quoted.
        case verbatim
        /// Quoted, with nothing inside needing attention: the value is the bytes between the two
        /// quotes.
        case quoted
        /// Quoted, and something inside needs a walk — a doubled quote, text after the closing quote,
        /// or a quote that never closed.
        case escaped
    }

    /// Offset of the field's first byte, its opening quote included.
    let start: UInt32
    /// One past the field's last byte, excluding the delimiter or line break that ended it.
    let end: UInt32
    let form: Form
}

/// The pass that splits delimited text into records and fields (2026-09-15).
///
/// RFC 4180 as spreadsheets write it, and as lenient as Python's `csv` module where the RFC says
/// nothing:
///
/// - A field that **starts** with `"` is quoted. Inside it, `""` is one quote and delimiters and line
///   breaks are ordinary text. That is the rule a naive split gets wrong: a real export whose cells
///   hold commas split into 13 to 18 fields a line where the file has 3.
/// - Text after a closing quote joins the field (`"ab"c` reads `abc`), and a quote *inside* an
///   unquoted field is literal. Neither is valid, and refusing either would refuse the file.
/// - A record ends at LF, CRLF or a lone CR, so a file written on any platform splits into lines.
/// - A blank line is no record, and a line break at the end of the file does not add one.
///
/// It works on bytes, and that is safe for UTF-8: the delimiter, the quote and both line breaks are
/// ASCII, and no byte of a multi-byte sequence is below 0x80.
enum DelimitedTextScanner {
    struct Result {
        var cells: [DelimitedCell] = []
        /// Index into `cells` where each record starts, plus one entry past the last record.
        var recordStarts = [0]
        /// Whether the last record ran into the end of the bytes rather than a line break. For a
        /// file cut at a read limit, that record is incomplete.
        var endsMidRecord = false
        /// How many bytes a quote that never closed ran to the end of the bytes, if one did.
        var unterminatedQuoteLength: Int?

        var recordCount: Int { recordStarts.count - 1 }

        func fieldCount(ofRecord record: Int) -> Int {
            recordStarts[record + 1] - recordStarts[record]
        }

        mutating func dropLastRecord() {
            guard recordCount > 0 else { return }
            recordStarts.removeLast()
            cells.removeSubrange((recordStarts.last ?? 0)...)
        }
    }

    static let quote: UInt8 = 0x22
    static let lineFeed: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D

    /// Split `bytes` on `delimiter`, stopping after `recordLimit` records.
    ///
    /// A UTF-8 byte-order mark at the start is skipped. `TextPreview` already removes one when it
    /// decodes a file, so this only matters to a caller handing in bytes of its own.
    static func scan(
        _ bytes: UnsafeBufferPointer<UInt8>,
        delimiter: UInt8,
        recordLimit: Int = .max
    ) -> Result {
        var result = Result()
        let count = bytes.count
        var position = hasByteOrderMark(bytes) ? 3 : 0
        var atRecordStart = true
        while position < count {
            if atRecordStart {
                let byte = bytes[position]
                if byte == lineFeed || byte == carriageReturn {
                    position += 1
                    continue
                }
                if result.recordCount >= recordLimit { break }
            }
            atRecordStart = false
            let field = scanField(bytes, from: position, delimiter: delimiter)
            result.cells.append(DelimitedCell(
                start: UInt32(position),
                end: UInt32(field.end),
                form: field.form
            ))
            if let open = field.unterminatedLength {
                result.unterminatedQuoteLength = open
            }
            position = field.end
            guard position < count else {
                result.endsMidRecord = true
                result.recordStarts.append(result.cells.count)
                return result
            }
            let terminator = bytes[position]
            position += 1
            if terminator == delimiter {
                // A delimiter at the very end leaves one empty field after it: `a,b,` is three.
                if position == count {
                    let end = UInt32(count)
                    result.cells.append(DelimitedCell(start: end, end: end, form: .verbatim))
                    result.endsMidRecord = true
                    result.recordStarts.append(result.cells.count)
                    return result
                }
                continue
            }
            if terminator == carriageReturn, position < count, bytes[position] == lineFeed {
                position += 1
            }
            result.recordStarts.append(result.cells.count)
            atRecordStart = true
        }
        return result
    }

    /// One field starting at `start`: where it ends (at its terminator, or the end of the bytes) and
    /// how its value is read.
    private static func scanField(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        delimiter: UInt8
    ) -> ScannedField {
        let count = bytes.count
        guard bytes[start] == quote else {
            var end = start
            while end < count, !isTerminator(bytes[end], delimiter: delimiter) {
                end += 1
            }
            return ScannedField(end: end, form: .verbatim)
        }
        var form = DelimitedCell.Form.quoted
        var index = start + 1
        while index < count {
            guard bytes[index] == quote else {
                index += 1
                continue
            }
            if index + 1 < count, bytes[index + 1] == quote {
                form = .escaped
                index += 2
                continue
            }
            // The closing quote. Anything before the terminator after it is malformed, and joins the
            // value rather than failing the file.
            var end = index + 1
            while end < count, !isTerminator(bytes[end], delimiter: delimiter) {
                form = .escaped
                end += 1
            }
            return ScannedField(end: end, form: form)
        }
        return ScannedField(end: count, form: .escaped, unterminatedLength: count - start)
    }

    /// Where a field ends and how its value is read, plus how far an unclosed quote ran.
    private struct ScannedField {
        let end: Int
        let form: DelimitedCell.Form
        var unterminatedLength: Int?
    }

    private static func isTerminator(_ byte: UInt8, delimiter: UInt8) -> Bool {
        byte == delimiter || byte == lineFeed || byte == carriageReturn
    }

    private static func hasByteOrderMark(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
    }
}
