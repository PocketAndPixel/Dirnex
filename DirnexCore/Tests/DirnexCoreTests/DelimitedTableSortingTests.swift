import Foundation
import Testing

@testable import DirnexCore

/// The order a column header click puts a table's rows in: numbers by value, text the way Finder
/// sorts names, blanks last, and ties in file order.
@Suite("DelimitedTable sorting")
struct DelimitedTableSortingTests {
    private func table(_ text: String) throws -> DelimitedTable {
        try #require(DelimitedTable.parse(text))
    }

    /// Column `column` read down the rows in the order the sort produced.
    private func sorted(_ table: DelimitedTable, column: Int, ascending: Bool = true) -> [String] {
        table.rowOrder(sortedByColumn: column, ascending: ascending)
            .map { table.cell(row: $0, column: column) }
    }

    /// Values chosen where a name sort and a value sort disagree: Finder's comparison already puts
    /// `9` before `10`, so plain integers cannot tell the two apart (a control found that), while it
    /// puts `1.5` before `1.25` and `-2` before `-10`.
    @Test("a numeric column sorts by value, not as text")
    func numbersByValue() throws {
        let parsed = try table("id,size\n1,1.5\n2,-2\n3,1.25\n4,-10\n5,10\n")
        #expect(parsed.numericColumns == [true, true])
        #expect(sorted(parsed, column: 1) == ["-10", "-2", "1.25", "1.5", "10"])
        #expect(sorted(parsed, column: 1, ascending: false) == ["10", "1.5", "1.25", "-2", "-10"])
    }

    @Test("a text column sorts as Finder sorts names: digits by value, case not deciding")
    func textLikeFinder() throws {
        let parsed = try table("name,note\nfile10,a\nFile2,bb\nfile1,ccc\napple,dddd\n")
        #expect(parsed.hasHeaderRow)
        #expect(sorted(parsed, column: 0) == ["apple", "file1", "File2", "file10"])
    }

    @Test("blanks sort last in both directions")
    func blanksLast() throws {
        let parsed = try table("name,size\nb,2\n,\na,1\nc,\n")
        #expect(sorted(parsed, column: 0) == ["a", "b", "c", ""])
        #expect(sorted(parsed, column: 0, ascending: false) == ["c", "b", "a", ""])
        #expect(sorted(parsed, column: 1, ascending: false) == ["2", "1", "", ""])
    }

    @Test("rows that compare equal keep their file order, in both directions")
    func stableTies() throws {
        let parsed = try table("group,id\nb,1\na,2\nb,3\na,4\nb,5\n")
        let ascending = parsed.rowOrder(sortedByColumn: 0, ascending: true)
        let descending = parsed.rowOrder(sortedByColumn: 0, ascending: false)
        #expect(ascending.map { parsed.cell(row: $0, column: 1) } == ["2", "4", "1", "3", "5"])
        #expect(descending.map { parsed.cell(row: $0, column: 1) } == ["1", "3", "5", "2", "4"])
    }

    @Test("a value in a numeric column that is not a number sorts after every number")
    func outliersAfterNumbers() throws {
        // Past the 200 rows the number guess samples, so the column is still numeric.
        let numbers = (1...200).map { "row\($0),\($0 % 7)" }.joined(separator: "\n")
        let parsed = try table("name,count\n\(numbers)\nlate,n/a\nlater,-1\n")
        #expect(parsed.numericColumns == [false, true])
        let order = sorted(parsed, column: 1)
        #expect(order.first == "-1")
        #expect(order.last == "n/a")
    }

    @Test("decimal commas and grouping separators read the way the file writes them")
    func separators() throws {
        let european = try table("item;price\na;10,25\nb;1,5\nc;2\n")
        #expect(sorted(european, column: 1) == ["1,5", "2", "10,25"])

        let grouped = try table("item,price\na,\"1,234\"\nb,999\nc,\"12,000.5\"\n")
        #expect(sorted(grouped, column: 1) == ["999", "1,234", "12,000.5"])
    }

    @Test("which separator is the decimal one, from the first value that can say")
    func decimalCommaEvidence() {
        #expect(DelimitedTable.usesDecimalComma(["1.234,56"], delimiter: .comma))
        #expect(!DelimitedTable.usesDecimalComma(["1,234.56"], delimiter: .semicolon))
        #expect(DelimitedTable.usesDecimalComma(["", "7", "1,5"], delimiter: .comma))
        #expect(!DelimitedTable.usesDecimalComma(["1,234,567"], delimiter: .semicolon))
        #expect(DelimitedTable.usesDecimalComma(["1.234.567"], delimiter: .comma))
        // Only three digits after a lone separator cannot say; the delimiter decides.
        #expect(DelimitedTable.usesDecimalComma(["1,234"], delimiter: .semicolon))
        #expect(!DelimitedTable.usesDecimalComma(["1,234"], delimiter: .comma))
    }

    @Test("numbers parse with their sign, fraction, exponent and percent sign")
    func numericValues() {
        #expect(DelimitedTable.numericValue("-.5", decimalComma: false) == -0.5)
        #expect(DelimitedTable.numericValue("45%", decimalComma: false) == 45)
        #expect(DelimitedTable.numericValue("6.02e23", decimalComma: false) == 6.02e23)
        #expect(DelimitedTable.numericValue(" 1.234,5 ", decimalComma: true) == 1234.5)
        #expect(DelimitedTable.numericValue("n/a", decimalComma: false) == nil)
    }

    @Test("the longest value in a column is counted over every row, its quotes and the header not")
    func longestValue() throws {
        let rows = (1...300).map { "r\($0),1" }.joined(separator: "\n")
        let parsed = try table("name,size\n\(rows)\nlast,\"1,234,567,890\"\n")
        #expect(parsed.longestValueByteCount(inColumn: 1) == 13)
        #expect(parsed.longestValueByteCount(inColumn: 0) == 4)
        #expect(parsed.longestValueByteCount(inColumn: 9) == 0)
    }

    @Test("a column the table does not have leaves the file order, and the header row is not a row")
    func edges() throws {
        let parsed = try table("name,x\nb,1\na,2\n")
        #expect(parsed.rowOrder(sortedByColumn: 5, ascending: true) == [0, 1])
        #expect(parsed.rowOrder(sortedByColumn: -1, ascending: false) == [0, 1])
        #expect(sorted(parsed, column: 0) == ["a", "b"])
    }
}
