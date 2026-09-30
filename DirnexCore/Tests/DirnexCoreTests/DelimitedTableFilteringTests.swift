import Foundation
import Testing

@testable import DirnexCore

/// Which rows the table filter keeps: a cell containing the text ignoring case, in any column or in
/// one, over the data rows only.
@Suite("DelimitedTable filtering")
struct DelimitedTableFilteringTests {
    private func table(_ text: String) throws -> DelimitedTable {
        try #require(DelimitedTable.parse(text))
    }

    @Test("a row is kept when any cell contains the text, whatever its case")
    func anyColumnIgnoringCase() throws {
        let parsed = try table("name,status\nAlpha,OK\nbeta,FAILED\nGamma,ok\n")
        #expect(parsed.rowsMatching("ok") == [true, false, true])
        #expect(parsed.rowsMatching("ALP") == [true, false, false])
        #expect(parsed.rowsMatching("a") == [true, true, true])
        #expect(parsed.rowsMatching("zzz") == [false, false, false])
    }

    /// The case the picker exists for, from a load-test log: `500` is a response code in one column
    /// and an ordinary number of milliseconds in another.
    @Test("a chosen column is the only one searched")
    func oneColumn() throws {
        let parsed = try table("label,code,elapsed\ncv/create,200,1500\ncv/update,500,120\n")
        #expect(parsed.rowsMatching("500") == [true, true])
        #expect(parsed.rowsMatching("500", inColumn: 1) == [false, true])
        #expect(parsed.rowsMatching("500", inColumn: 2) == [true, false])
        #expect(parsed.rowsMatching("500", inColumn: 3) == [false, false])
        #expect(parsed.rowsMatching("500", inColumn: -1) == [false, false])
    }

    @Test("the header row is not searched, and an empty text keeps every row")
    func dataRowsOnly() throws {
        let parsed = try table("label,code\ncreate,200\nupdate,500\n")
        #expect(parsed.hasHeaderRow)
        #expect(parsed.rowsMatching("label") == [false, false])
        #expect(parsed.rowsMatching("") == [true, true])
    }

    @Test("a row short of the column searched does not match it")
    func shortRows() throws {
        let parsed = try table("a,b,c\n1,2,3\n4\n5,6,777\n")
        #expect(parsed.rowsMatching("7", inColumn: 2) == [false, false, true])
        #expect(parsed.rowsMatching("4") == [false, true, false])
    }

    @Test("a text never runs across two cells, and inside quotes a delimiter is ordinary text")
    func cellBoundaries() throws {
        let parsed = try table("left,right\na,b\n\"a,b\",c\n")
        #expect(parsed.rowsMatching("a,b") == [false, true])
        #expect(parsed.rowsMatching("ab") == [false, false])
    }

    @Test("text outside ASCII is matched ignoring case, and its accents count")
    func beyondASCII() throws {
        let parsed = try table("name\nПривет мир\nÄRGER\nRésumé\nйод\n")
        #expect(parsed.rowsMatching("привет") == [true, false, false, false])
        #expect(parsed.rowsMatching("ärger") == [false, true, false, false])
        #expect(parsed.rowsMatching("résumé") == [false, false, true, false])
        // Accents are part of the text: `resume` is not `résumé`, and `й` is not `и`.
        #expect(parsed.rowsMatching("resume") == [false, false, false, false])
        #expect(parsed.rowsMatching("иод") == [false, false, false, false])
    }

    /// The ASCII path reads bytes in place and every other path decodes, so the two are held to one
    /// answer over every form a cell comes in: plain, quoted, quoted with a doubled quote, and quoted
    /// with text after the closing quote — at the edges of each value as well as inside.
    @Test("reading bytes in place gives the answer decoding every cell gives")
    func inPlaceAgreesWithDecoding() throws {
        let parsed = try table(#"""
        name,note,code
        "Alpha, Inc","He said ""HI""",A1
        beta,"x"yz,b2
        GAMMA,plain,
        "quoted",,C3
        short

        """#)
        let needles = [
            "a", "alpha, inc", "inc", "\"", #""hi""#, #"said ""#, "xyz", "yz", #"x""#, "zz",
            "c3", "a1", ",", "short", "plain", "quoted", #""quoted""#, "gamma,", #"he said ""hi"""#
        ]
        for needle in needles {
            for column in [nil, 0, 1, 2] as [Int?] {
                let columns = column.map { [$0] } ?? Array(0..<parsed.columnCount)
                let expected = (0..<parsed.rowCount).map { row in
                    columns.contains { Self.decoded(parsed, row: row, column: $0, contains: needle) }
                }
                #expect(
                    parsed.rowsMatching(needle, inColumn: column) == expected,
                    "\(needle) in \(String(describing: column))"
                )
            }
        }
    }

    /// The rule spelled the slow way, as the oracle for the fast one: decode the cell, then compare.
    private static func decoded(
        _ table: DelimitedTable,
        row: Int,
        column: Int,
        contains needle: String
    ) -> Bool {
        table.cell(row: row, column: column).lowercased().contains(needle)
    }

    @Test("a cancelled filter answers nothing rather than part of an answer")
    func cancellation() throws {
        let parsed = try table("a\n1\n2\n")
        #expect(parsed.rowsMatching("1", isCancelled: { true }) == nil)
        #expect(parsed.rowsMatching("1", isCancelled: { false }) == [true, false])
    }
}
