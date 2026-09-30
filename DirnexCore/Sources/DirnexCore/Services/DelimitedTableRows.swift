/// The rows Quick View's table draws, and in what order: the file's data rows, put in a sort's order
/// and narrowed to a filter's matches (2026-09-15).
///
/// A sort and a filter each answer over the whole file and know nothing of each other — a sort is a
/// permutation of every row, a filter a yes or no for each — so either can change without the other
/// being run again. This is where the two meet, and it is the one place a drawn row is turned into a
/// row of the file and back. The rows themselves are never moved, which is what lets a row keep its
/// number from the file however it is sorted or filtered.
public struct DelimitedTableRows: Sendable, Equatable {
    /// How many rows are drawn.
    public let count: Int
    /// Whether none are.
    public let isEmpty: Bool
    /// The file row drawn at each position, or `nil` while every row is drawn in the file's order.
    private let records: [Int]?
    /// Where each file row is drawn, `-1` for one the filter leaves out; `nil` with `records`.
    private let positions: [Int]?

    /// `rowCount` rows, in `order` when there is one (a permutation of them all) and only those
    /// `matches` keeps when there is a filter. A position either leaves out is taken to be in the
    /// file's order, or kept.
    public init(rowCount: Int, order: [Int]? = nil, matches: [Bool]? = nil) {
        guard order != nil || matches != nil else {
            count = max(rowCount, 0)
            isEmpty = rowCount <= 0
            records = nil
            positions = nil
            return
        }
        let ordered = order ?? Array(0..<max(rowCount, 0))
        let kept = ordered.filter { record in
            guard record >= 0, record < rowCount else { return false }
            guard let matches, matches.indices.contains(record) else { return true }
            return matches[record]
        }
        var positions = [Int](repeating: -1, count: max(rowCount, 0))
        for (position, record) in kept.enumerated() {
            positions[record] = position
        }
        count = kept.count
        isEmpty = kept.isEmpty
        records = kept
        self.positions = positions
    }

    /// Whether a filter has left rows out.
    public var isNarrowed: Bool {
        guard let positions else { return false }
        return count < positions.count
    }

    /// The file row drawn at `row`. A row past the end is answered as itself, which no caller asks
    /// for on purpose and which keeps a stale index from trapping.
    public func record(atRow row: Int) -> Int {
        guard let records, records.indices.contains(row) else { return row }
        return records[row]
    }

    /// Where file row `record` is drawn, or `nil` when the filter leaves it out or the file has no
    /// such row.
    public func row(ofRecord record: Int) -> Int? {
        guard let positions else { return record >= 0 && record < count ? record : nil }
        guard positions.indices.contains(record), positions[record] >= 0 else { return nil }
        return positions[record]
    }
}
