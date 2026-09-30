import Foundation
import Testing

@testable import DirnexCore

/// Splitting delimited text into records and fields — the quoting rules a naive split gets wrong,
/// and the shapes a real file arrives in: CRLF, a BOM, a trailing delimiter, a file cut at the read
/// limit.
@Suite("DelimitedTable parsing")
struct DelimitedTableParsingTests {
    private func table(
        _ text: String,
        isTruncated: Bool = false,
        hint: DelimitedTable.Delimiter? = nil
    ) throws -> DelimitedTable {
        try #require(DelimitedTable.parse(text, isTruncated: isTruncated, delimiterHint: hint))
    }

    /// Every record as the values it holds, the header row included — what the file says, with the
    /// header guess taken out of the comparison.
    private func records(_ table: DelimitedTable) -> [[String]] {
        (0..<table.recordCount).map { record in
            table.cells[table.recordStarts[record]..<table.recordStarts[record + 1]]
                .map { DelimitedTable.value(of: $0, in: table.bytes) }
        }
    }

    // MARK: - Fields

    @Test("plain fields split on the delimiter, and each line is a record")
    func plain() throws {
        let parsed = try table("name,city\nAlice,Paris\nBob,Berlin\n")
        #expect(records(parsed) == [["name", "city"], ["Alice", "Paris"], ["Bob", "Berlin"]])
        #expect(parsed.columnCount == 2)
    }

    @Test("a delimiter inside quotes is text, and a doubled quote is one quote")
    func quoting() throws {
        // The shape of a real Dynamics export that splits into 13 fields on its commas and has 3.
        let text = """
        Record,Keys,Values
        "[[@odata.etag, W/""6202491014""], [name, NORTH (01 - 2R)]...]","[etag, name]","[W/""62"", NORTH...]"
        """ + "\n"
        let parsed = try table(text)
        #expect(parsed.columnCount == 3)
        #expect(parsed.rowCount == 1)
        #expect(parsed.cell(row: 0, column: 0)
            == "[[@odata.etag, W/\"6202491014\"], [name, NORTH (01 - 2R)]...]")
        #expect(parsed.cell(row: 0, column: 2) == "[W/\"62\", NORTH...]")
    }

    @Test("a line break inside quotes stays in the field")
    func lineBreakInQuotes() throws {
        let parsed = try table("id,note\n1,\"first line\r\nsecond line\"\n2,plain\n")
        #expect(
            records(parsed) == [["id", "note"], ["1", "first line\r\nsecond line"], ["2", "plain"]]
        )
    }

    @Test("empty quoted fields, a lone escaped quote, and a quote inside an unquoted field")
    func quoteEdges() throws {
        let parsed = try table("a,b,c\n\"\",\"\"\"\",say \"hi\"\n")
        #expect(records(parsed)[1] == ["", "\"", "say \"hi\""])
    }

    @Test("text after a closing quote joins the field rather than failing the file")
    func textAfterClosingQuote() throws {
        let parsed = try table("a,b\n\"ab\"c,\"x\"y\"z\n")
        #expect(records(parsed)[1] == ["abc", "xy\"z"])
    }

    @Test("CRLF, a lone CR and LF all end a record")
    func lineEndings() throws {
        let parsed = try table("a,b\r\n1,2\r3,4\n5,6")
        #expect(records(parsed) == [["a", "b"], ["1", "2"], ["3", "4"], ["5", "6"]])
    }

    @Test("blank lines are no record, and a trailing line break adds none")
    func blankLines() throws {
        let parsed = try table("\n\na,b\n\n1,2\r\n\r\n3,4\n\n")
        #expect(records(parsed) == [["a", "b"], ["1", "2"], ["3", "4"]])
    }

    @Test("a trailing delimiter leaves an empty last field, at a line break and at the end")
    func trailingDelimiter() throws {
        let parsed = try table("a,b,\n1,2,")
        #expect(records(parsed) == [["a", "b", ""], ["1", "2", ""]])
    }

    @Test("a short row reads as empty in the columns it does not reach")
    func raggedRows() throws {
        let parsed = try table("a,b,c\n1\n1,2,3,4\n")
        #expect(parsed.columnCount == 4)
        #expect(parsed.values(ofRow: 0) == ["1", "", "", ""])
        #expect(parsed.cell(row: 1, column: 3) == "4")
        #expect(parsed.title(ofColumn: 3) == "D")
        #expect(parsed.cell(row: 7, column: 0).isEmpty)
        #expect(parsed.cell(row: 0, column: -1).isEmpty)
    }

    @Test("a byte-order mark is not part of the first field")
    func byteOrderMark() throws {
        let parsed = try table("\u{FEFF}name,city\nAlice,Paris\n")
        #expect(parsed.title(ofColumn: 0) == "name")
    }

    @Test("non-ASCII values survive whole")
    func unicode() throws {
        let parsed = try table("город;эмодзи\nМосква;👩‍💻 кодит\n")
        #expect(parsed.delimiter == .semicolon)
        #expect(parsed.values(ofRow: 0) == ["Москва", "👩‍💻 кодит"])
    }

    // MARK: - Where a file stops

    @Test(
        "an unclosed quote in a whole file is refused, since every field after it has run together"
    )
    func unterminatedQuote() {
        #expect(DelimitedTable.parse("a,b\n\"never closed,1\n2,3\n") == nil)
    }

    @Test("a file cut at the read limit drops its incomplete last record")
    func truncatedMidRecord() throws {
        let parsed = try table("a,b\n1,2\n3,4", isTruncated: true)
        #expect(records(parsed) == [["a", "b"], ["1", "2"]])
        let untruncated = try table("a,b\n1,2\n3,4")
        #expect(untruncated.rowCount == 2)
    }

    @Test("a file cut inside a quoted field drops that record, unless the quote has run too long")
    func truncatedInsideQuotes() throws {
        let parsed = try table("a,b\n1,2\n3,\"cut mid", isTruncated: true)
        #expect(records(parsed) == [["a", "b"], ["1", "2"]])

        let swallowed = "a,b\n1,\"" + String(
            repeating: "x",
            count: DelimitedTable.longestPlausibleOpenQuote
        )
        #expect(DelimitedTable.parse(swallowed, isTruncated: true) == nil)
    }

    @Test("a cut that lands on a line break keeps every record")
    func truncatedAtLineBreak() throws {
        let parsed = try table("a,b\n1,2\n", isTruncated: true)
        #expect(parsed.rowCount == 1)
    }

    @Test("no records at all is no table")
    func empty() {
        #expect(DelimitedTable.parse("") == nil)
        #expect(DelimitedTable.parse("\n\r\n\n") == nil)
    }

    // MARK: - Leaving the table

    @Test("column letters run A to Z, then AA, as spreadsheets name them")
    func columnLetters() {
        #expect(DelimitedTable.columnLetters(0) == "A")
        #expect(DelimitedTable.columnLetters(25) == "Z")
        #expect(DelimitedTable.columnLetters(26) == "AA")
        #expect(DelimitedTable.columnLetters(701) == "ZZ")
        #expect(DelimitedTable.columnLetters(702) == "AAA")
    }

    @Test("a blank header cell is titled by its letter")
    func blankHeaderTitle() throws {
        let parsed = try table(",name\n1,Alice\n2,Bob\n")
        #expect(parsed.hasHeaderRow)
        #expect(parsed.title(ofColumn: 0) == "A")
        #expect(parsed.title(ofColumn: 1) == "name")
    }

    @Test("copied rows are tab-separated, full width, and quoted where a value needs it")
    func tabSeparatedCopy() throws {
        let parsed = try table("a,b,c\n1,\"x\ty\",3\n\"say \"\"hi\"\"\",\"two\nlines\"\n")
        #expect(parsed.tabSeparatedText(rows: [0, 1, 9])
            == "1\t\"x\ty\"\t3\n\"say \"\"hi\"\"\"\t\"two\nlines\"\t")
    }

    @Test("field spans are UTF-16 ranges of each field as written, with its column")
    func fieldSpans() throws {
        let text = "имя,\"😀, ok\"\r\nБоб,,x\n"
        let parsed = try table(text)
        let spans = parsed.fieldSpans()
        let source = text as NSString
        let written = spans.map { source.substring(
            with: NSRange(location: $0.offset, length: $0.length)
        ) }
        // The empty field has no span: there is nothing in it to color.
        #expect(written == ["имя", "\"😀, ok\"", "Боб", "x"])
        #expect(spans.map(\.column) == [0, 1, 0, 2])
        #expect(parsed.fieldSpans(limit: 2).count == 2)
    }
}
