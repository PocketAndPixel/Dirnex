import Foundation
import Testing

@testable import DirnexCore

/// The guesses a delimited file needs: its delimiter, whether its first row names the columns, and
/// which columns hold numbers. The fixtures are the shapes of the CSVs found on the Mac this was
/// written on — a benchmark matrix, a load-test log, a speech dataset's pipe-separated metadata and a
/// CRM export whose cells are full of commas — with the data replaced.
@Suite("DelimitedTable detection")
struct DelimitedTableDetectionTests {
    // MARK: - Delimiter

    @Test("commas inside quotes do not outvote the real delimiter")
    func quotedCommas() throws {
        let text = """
        Record,Keys,Values
        "[[etag, W/""1""], [name, A, B]]","[etag, name, team, city]","[W/""1"", A, B, C]"
        "[[etag, W/""2""], [name, C, D]]","[etag, name, team]","[W/""2"", C, D]"

        """
        let table = try #require(DelimitedTable.parse(text))
        #expect(table.delimiter == .comma)
        #expect(table.columnCount == 3)
    }

    @Test(
        "a semicolon file with decimal commas is read on its semicolons when a header row settles it"
    )
    func semicolonWithDecimalCommas() throws {
        let table = try #require(
            DelimitedTable.parse("Name;Price;Weight\nApple;1,5;0,2\nPear;2,25;0,3\n")
        )
        #expect(table.delimiter == .semicolon)
        #expect(table.values(ofRow: 1) == ["Pear", "2,25", "0,3"])
    }

    @Test("tab and pipe files are recognized")
    func tabAndPipe() throws {
        let tab = try #require(DelimitedTable.parse("a\tb, c\n1\t2, 3\n4\t5\n"))
        #expect(tab.delimiter == .tab)
        let pipe = try #require(DelimitedTable.parse("""
        wavs/clip_0001.wav|Thanks so much, for taking the time.
        wavs/clip_0002.wav|I've been looking forward to this.
        wavs/clip_0003.wav|Let me start, by telling you a little.

        """))
        #expect(pipe.delimiter == .pipe)
        #expect(pipe.columnCount == 2)
    }

    @Test("the hint decides a tie, and is the answer when no delimiter fits")
    func hint() throws {
        // Every record splits into two on the comma and on the tab alike.
        let tied = "a,b\tc\n1,2\t3\n"
        #expect(DelimitedTable.parse(tied)?.delimiter == .comma)
        #expect(DelimitedTable.parse(tied, delimiterHint: .tab)?.delimiter == .tab)

        let single = try #require(DelimitedTable.parse("names\nAlice\nBob\n", delimiterHint: .tab))
        #expect(single.delimiter == .tab)
        #expect(single.columnCount == 1)
        #expect(DelimitedTable.parse("names\nAlice\nBob\n")?.delimiter == .comma)
    }

    @Test("more consistent records beat more fields")
    func consistencyFirst() throws {
        // Semicolons split every record into three; commas split two into three and leave the first whole.
        let text = "a;b;c\n1,2;3,4;5\n6;7,8,9;0\n"
        #expect(DelimitedTable.parse(text)?.delimiter == .semicolon)
    }

    // MARK: - Header row

    @Test("a name over a column of numbers is a header")
    func headerOverNumbers() throws {
        let table = try #require(DelimitedTable.parse("""
        timeStamp,elapsed,label,responseCode
        1774009760809,4458,attachment/cv/create,200
        1774009763813,1475,attachment/cv/create,200

        """))
        #expect(table.hasHeaderRow)
        #expect(table.rowCount == 2)
        #expect(table.title(ofColumn: 0) == "timeStamp")
    }

    @Test("a first row the same length as the rest of its column is data")
    func noHeaderFixedLength() throws {
        let table = try #require(DelimitedTable.parse("""
        wavs/clip_0001.wav|Thanks so much for taking the time.
        wavs/clip_0002.wav|I've been looking forward to this.
        wavs/clip_0003.wav|Let me start.

        """))
        #expect(!table.hasHeaderRow)
        #expect(table.rowCount == 3)
        #expect(table.title(ofColumn: 0) == "A")
        #expect(table.cell(row: 0, column: 0) == "wavs/clip_0001.wav")
    }

    @Test("a number in the first row, over a column of numbers, is data")
    func noHeaderNumbers() throws {
        let table = try #require(DelimitedTable.parse("Alice,30\nBob,25\nCarol,41\n"))
        #expect(!table.hasHeaderRow)
    }

    @Test("with no evidence either way, distinct names with no number in them are a header")
    func headerByDefault() throws {
        let named = try #require(DelimitedTable.parse("name,city\nAlice,Paris\nBob,Berlin\n"))
        #expect(named.hasHeaderRow)
        let repeated = try #require(DelimitedTable.parse("x,x\nAlice,Paris\nBob,Berlin\n"))
        #expect(!repeated.hasHeaderRow)
    }

    @Test("a single record is data, since there is nothing for it to name")
    func singleRecord() throws {
        let table = try #require(DelimitedTable.parse("name,city\n"))
        #expect(!table.hasHeaderRow)
        #expect(table.rowCount == 1)
    }

    // MARK: - Numbers

    @Test("what reads as a number, and what does not")
    func looksNumeric() {
        for value in [
            "0",
            "-12",
            "+3.5",
            "-.5",
            "1,234.56",
            "1.234,56",
            "6.02e23",
            "1E-9",
            "45%",
            " 7 "
        ] {
            #expect(DelimitedTable.looksNumeric(value), "\(value)")
        }
        for value in [
            "",
            "-",
            ".",
            "1..2",
            "12.",
            "2026-09-15",
            "1.2.3a",
            "e5",
            "1e",
            "12 345",
            "N/A"
        ] {
            #expect(!DelimitedTable.looksNumeric(value), "\(value)")
        }
    }

    @Test("a column is numeric when every sampled value is, ignoring empty cells")
    func numericColumns() throws {
        let table = try #require(DelimitedTable.parse("""
        id,name,price,missing,mixed
        1,Apple,1.50,,3
        2,Pear,,,n/a
        3,Plum,-0.75,,4

        """))
        #expect(table.numericColumns == [true, false, true, false, false])
    }

    @Test("a header-less file samples its first row for numbers too")
    func numericWithoutHeader() throws {
        // The two fixed-length columns vote the first row data; the middle column's `q` is in it.
        let table = try #require(DelimitedTable.parse("ab,q,x\ncd,2,y\nef,3,z\n"))
        #expect(!table.hasHeaderRow)
        #expect(table.numericColumns == [false, false, false])
        let numbers = try #require(DelimitedTable.parse("ab,1,x\ncd,2,y\nef,3,z\n"))
        #expect(numbers.numericColumns == [false, true, false])
    }
}
