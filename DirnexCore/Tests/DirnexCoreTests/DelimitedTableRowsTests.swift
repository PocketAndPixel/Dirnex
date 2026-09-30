import Testing

@testable import DirnexCore

/// Where a sort and a filter meet: which file row each drawn row is, and where each file row is drawn.
@Suite("DelimitedTable rows")
struct DelimitedTableRowsTests {
    @Test("with neither a sort nor a filter, every row is drawn where it is in the file")
    func fileOrder() {
        let rows = DelimitedTableRows(rowCount: 3)
        #expect(rows.count == 3)
        #expect((0..<3).map(rows.record(atRow:)) == [0, 1, 2])
        #expect((0..<3).map(rows.row(ofRecord:)) == [0, 1, 2])
        #expect(rows.row(ofRecord: 3) == nil)
        #expect(!rows.isNarrowed)
    }

    @Test("a sort alone puts every row where the sort says, and back")
    func sortOnly() {
        let rows = DelimitedTableRows(rowCount: 4, order: [2, 0, 3, 1])
        #expect(rows.count == 4)
        #expect((0..<4).map(rows.record(atRow:)) == [2, 0, 3, 1])
        #expect((0..<4).map(rows.row(ofRecord:)) == [1, 3, 0, 2])
        #expect(!rows.isNarrowed)
    }

    @Test("a filter alone keeps its rows in the file's order and has no place for the rest")
    func filterOnly() {
        let rows = DelimitedTableRows(rowCount: 4, matches: [true, false, true, false])
        #expect(rows.count == 2)
        #expect((0..<2).map(rows.record(atRow:)) == [0, 2])
        #expect((0..<4).map(rows.row(ofRecord:)) == [0, nil, 1, nil])
        #expect(rows.isNarrowed)
    }

    @Test("a sort and a filter together keep the sort's order among the rows the filter keeps")
    func sortAndFilter() {
        let rows = DelimitedTableRows(
            rowCount: 4,
            order: [3, 1, 2, 0],
            matches: [true, false, true, true]
        )
        #expect(rows.count == 3)
        #expect((0..<3).map(rows.record(atRow:)) == [3, 2, 0])
        #expect((0..<4).map(rows.row(ofRecord:)) == [2, nil, 1, 0])
    }

    @Test("a filter keeping every row narrows nothing, and one keeping none leaves nothing drawn")
    func edges() {
        let all = DelimitedTableRows(rowCount: 2, matches: [true, true])
        #expect(all.count == 2)
        #expect(!all.isNarrowed)
        let none = DelimitedTableRows(rowCount: 2, order: [1, 0], matches: [false, false])
        #expect(none.isEmpty)
        #expect(none.isNarrowed)
        #expect(none.row(ofRecord: 0) == nil)
    }
}
