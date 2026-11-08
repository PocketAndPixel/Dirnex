import Foundation

/// How the byte view divides a file into rows (PLAN.md §M37 Slice 1).
public enum BinaryHexLayout {
    public static let bytesPerRow = 16
    /// How many characters of hex text a full row takes: two for a byte, a space between bytes, and
    /// a second space between the two halves.
    public static let hexLength = 3 * bytesPerRow

    /// How many rows it takes to show `byteCount` bytes.
    public static func rowCount(forByteCount byteCount: Int64) -> Int64 {
        (byteCount + Int64(bytesPerRow) - 1) / Int64(bytesPerRow)
    }

    /// The row holding the byte at `offset`.
    public static func row(containing offset: Int64) -> Int64 {
        offset / Int64(bytesPerRow)
    }

    /// The first byte of row `row`.
    public static func offset(ofRow row: Int64) -> Int64 {
        row * Int64(bytesPerRow)
    }

    /// How many hex digits the offset column needs for a file of `byteCount` bytes: eight, unless
    /// the file is too large for them.
    public static func offsetDigits(forByteCount byteCount: Int64) -> Int {
        max(8, String(max(byteCount - 1, 0), radix: 16).count)
    }

    /// `offset` in hex, zero-filled to `digits`.
    public static func offsetText(_ offset: Int64, digits: Int) -> String {
        let text = String(offset, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    /// Where byte `column` is in a row's hex text: its two digits.
    public static func hexRange(ofColumn column: Int) -> Range<Int> {
        let start = 3 * column + (column >= bytesPerRow / 2 ? 1 : 0)
        return start..<(start + 2)
    }
}

/// One row of the byte view: up to sixteen bytes of each file, from the same offset (PLAN.md §M37
/// Slice 1).
public struct BinaryHexRow: Sendable, Equatable {
    public let offset: Int64
    /// The left file's bytes on this row: all sixteen, or fewer at the end of the file.
    public let left: [UInt8]
    /// The right file's bytes on this row.
    public let right: [UInt8]

    public init(offset: Int64, left: [UInt8], right: [UInt8]) {
        self.offset = offset
        self.left = left
        self.right = right
    }

    /// Whether the two files disagree at `column`. A byte only one side has is a disagreement.
    public func differs(atColumn column: Int) -> Bool {
        let leftByte = left.indices.contains(column) ? left[column] : nil
        let rightByte = right.indices.contains(column) ? right[column] : nil
        return leftByte != rightByte
    }

    /// The columns where the two files disagree, in order.
    public var differingColumns: [Int] {
        (0..<BinaryHexLayout.bytesPerRow).filter(differs(atColumn:))
    }

    /// One side as hex digits: `4A 6F` and so on, with a wider space down the middle. A column the
    /// side has no byte for is blank, so the columns stay under one another.
    public func hexText(_ side: ComparisonPaneText.Side) -> String {
        let bytes = side == .left ? left : right
        var text = ""
        text.reserveCapacity(BinaryHexLayout.hexLength)
        for column in 0..<BinaryHexLayout.bytesPerRow {
            if column > 0 {
                text += column == BinaryHexLayout.bytesPerRow / 2 ? "  " : " "
            }
            if bytes.indices.contains(column) {
                text.append(Self.hexDigit(bytes[column] >> 4))
                text.append(Self.hexDigit(bytes[column] & 0x0F))
            } else {
                text += "  "
            }
        }
        return text
    }

    /// One side as characters: printable ASCII as itself and anything else as `·`, one character
    /// per byte, with a blank for a column the side has no byte for.
    ///
    /// A byte is only a character by coincidence here, so nothing past ASCII is decoded: half of a
    /// UTF-8 sequence would otherwise draw as whatever Latin letter it happens to be.
    public func characterText(_ side: ComparisonPaneText.Side) -> String {
        let bytes = side == .left ? left : right
        var text = ""
        text.reserveCapacity(BinaryHexLayout.bytesPerRow)
        for column in 0..<BinaryHexLayout.bytesPerRow {
            guard bytes.indices.contains(column) else {
                text.append(" ")
                continue
            }
            let byte = bytes[column]
            text.append((0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : "\u{B7}")
        }
        return text
    }

    private static func hexDigit(_ value: UInt8) -> Character {
        Character(UnicodeScalar(value < 10 ? 0x30 + value : 0x41 + value - 10))
    }
}

/// A run of both files read together, cut into rows on demand (PLAN.md §M37 Slice 1).
public struct BinaryPage: Sendable, Equatable {
    /// Thousands of rows, so one read covers a screen and the scroll around it. A multiple of the
    /// row width, so no row spans two pages.
    public static let byteCount = 64 * 1024

    public let index: Int64
    public let left: [UInt8]
    public let right: [UInt8]

    public init(index: Int64, left: [UInt8], right: [UInt8]) {
        self.index = index
        self.left = left
        self.right = right
    }

    /// The page holding row `row`.
    public static func index(ofRow row: Int64) -> Int64 {
        BinaryHexLayout.offset(ofRow: row) / Int64(byteCount)
    }

    /// Row `row`, which has to be on this page. Empty on a side that ended before the row.
    public func row(_ row: Int64) -> BinaryHexRow {
        let offset = BinaryHexLayout.offset(ofRow: row)
        precondition(Self.index(ofRow: row) == index, "a row read from another page")
        let start = Int(offset - index * Int64(Self.byteCount))
        return BinaryHexRow(
            offset: offset,
            left: Self.slice(left, from: start),
            right: Self.slice(right, from: start)
        )
    }

    private static func slice(_ bytes: [UInt8], from start: Int) -> [UInt8] {
        guard start < bytes.count else { return [] }
        return Array(bytes[start..<min(start + BinaryHexLayout.bytesPerRow, bytes.count)])
    }
}

/// The most recently read pages, so scrolling back over them reads nothing (PLAN.md §M37 Slice 1).
public struct BinaryPageCache: Sendable {
    /// Enough for several screens either way at a few megabytes in all.
    public static let defaultCapacity = 64

    private var pages: [Int64: BinaryPage] = [:]
    private var lastUse: [Int64: UInt64] = [:]
    private var clock: UInt64 = 0
    public let capacity: Int

    public init(capacity: Int = defaultCapacity) {
        precondition(capacity > 0, "a cache has to hold something")
        self.capacity = capacity
    }

    public var count: Int {
        pages.count
    }

    /// The page at `index` if it is held, which counts as a use of it.
    public mutating func page(_ index: Int64) -> BinaryPage? {
        guard let page = pages[index] else { return nil }
        touch(index)
        return page
    }

    /// Hold `page`, letting go of the page used longest ago when full.
    public mutating func insert(_ page: BinaryPage) {
        if pages[page.index] == nil, pages.count >= capacity,
           let oldest = lastUse.min(by: { $0.value < $1.value })?.key {
            pages[oldest] = nil
            lastUse[oldest] = nil
        }
        pages[page.index] = page
        touch(page.index)
    }

    private mutating func touch(_ index: Int64) {
        clock += 1
        lastUse[index] = clock
    }
}
