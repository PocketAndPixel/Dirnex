import Foundation
import Testing

@testable import DirnexCore

/// What the byte view draws (PLAN.md §M37 Slice 1): rows, pages read on demand, and the cache.
@Suite("Byte view rows and pages")
struct BinaryHexRowTests {
    // MARK: - Layout

    @Test("rows hold sixteen bytes", arguments: [
        (Int64(0), Int64(0)), (1, 1), (16, 1), (17, 2), (32, 2), (33, 3)
    ])
    func rowCount(bytes: Int64, rows: Int64) {
        #expect(BinaryHexLayout.rowCount(forByteCount: bytes) == rows)
    }

    @Test("a row and its first offset are inverses")
    func rowAndOffset() {
        #expect(BinaryHexLayout.row(containing: 0) == 0)
        #expect(BinaryHexLayout.row(containing: 15) == 0)
        #expect(BinaryHexLayout.row(containing: 16) == 1)
        #expect(BinaryHexLayout.offset(ofRow: 3) == 48)
        #expect(
            BinaryHexLayout.offset(ofRow: BinaryHexLayout.row(containing: 1_000_000_007)) == 1_000_000_000
        )
    }

    @Test("the offset column is eight digits until a file needs more", arguments: [
        (Int64(0), 8), (1, 8), (0x1_0000_0000, 8), (0x1_0000_0001, 9), (0x10_0000_0001, 10)
    ])
    func offsetDigits(bytes: Int64, digits: Int) {
        #expect(BinaryHexLayout.offsetDigits(forByteCount: bytes) == digits)
    }

    @Test("an offset is written in zero-filled capitals")
    func offsetText() {
        #expect(BinaryHexLayout.offsetText(0xAB, digits: 8) == "000000AB")
        #expect(BinaryHexLayout.offsetText(0x1_2345_6789, digits: 8) == "123456789")
    }

    @Test("a column's digits are where the text says they are", arguments: 0..<16)
    func hexRanges(column: Int) {
        let row = BinaryHexRow(offset: 0, left: Array(0..<16), right: [])
        let text = Array(row.hexText(.left))
        let range = BinaryHexLayout.hexRange(ofColumn: column)
        let digits = String(text[range])
        #expect(digits == String(format: "%02X", column))
    }

    // MARK: - Text

    @Test("a full row is sixteen pairs with a wider space down the middle")
    func hexTextOfAFullRow() {
        let bytes: [UInt8] = Array(0..<8) + [0xA0, 0xB1, 0xC2, 0xD3, 0xE4, 0xF5, 0x06, 0x7F]
        let row = BinaryHexRow(offset: 0, left: bytes, right: [])
        #expect(row.hexText(.left) == "00 01 02 03 04 05 06 07  A0 B1 C2 D3 E4 F5 06 7F")
        #expect(row.hexText(.left).count == BinaryHexLayout.hexLength)
    }

    @Test("a short row is padded, so its columns stay under the ones above")
    func hexTextOfAShortRow() {
        let row = BinaryHexRow(offset: 0, left: [0xAB], right: [])
        #expect(
            row.hexText(.left) == "AB" + String(repeating: " ", count: BinaryHexLayout.hexLength - 2)
        )
        #expect(row.hexText(.right) == String(repeating: " ", count: BinaryHexLayout.hexLength))
    }

    @Test("printable ASCII shows as itself, and the rest as a dot")
    func characterText() {
        let bytes: [UInt8] = [0x41, 0x20, 0x7E, 0x7F, 0x1F, 0x00, 0x80, 0xC3]
        let row = BinaryHexRow(offset: 0, left: bytes, right: [0x41])
        let dots = String(repeating: "\u{B7}", count: 5)
        #expect(row.characterText(.left) == "A ~" + dots + String(repeating: " ", count: 8))
        #expect(row.characterText(.right) == "A" + String(repeating: " ", count: 15))
    }

    @Test("half of a UTF-8 sequence is a dot, never a Latin letter")
    func characterTextDoesNotDecode() {
        let bytes = Array("é".utf8)
        #expect(
            BinaryHexRow(offset: 0, left: bytes, right: []).characterText(.left).hasPrefix(
                "\u{B7}\u{B7}"
            )
        )
    }

    // MARK: - Differences

    @Test("columns differ where the bytes do")
    func differingColumns() {
        let row = BinaryHexRow(offset: 0, left: [1, 2, 3], right: [1, 9, 3])
        #expect(row.differingColumns == [1])
        #expect(row.differs(atColumn: 1))
        #expect(!row.differs(atColumn: 0))
    }

    @Test("a byte only one side has is a difference, and no bytes on both sides is not")
    func oneSidedColumns() {
        let row = BinaryHexRow(offset: 0, left: [1, 2], right: [1])
        #expect(row.differingColumns == [1])
        #expect(!row.differs(atColumn: 15))
    }

    // MARK: - Pages

    @Test("a page knows which rows are on it")
    func pageOfRow() {
        let rowsPerPage = Int64(BinaryPage.byteCount / BinaryHexLayout.bytesPerRow)
        #expect(BinaryPage.index(ofRow: 0) == 0)
        #expect(BinaryPage.index(ofRow: rowsPerPage - 1) == 0)
        #expect(BinaryPage.index(ofRow: rowsPerPage) == 1)
    }

    @Test("a page is a whole number of rows, so no row spans two")
    func pageIsWholeRows() {
        #expect(BinaryPage.byteCount % BinaryHexLayout.bytesPerRow == 0)
    }

    @Test("a row comes off the page at its own offset, short where a file ended")
    func rowsOffAPage() {
        let page = BinaryPage(
            index: 1,
            left: Array(repeating: 7, count: 40),
            right: Array(repeating: 8, count: 16)
        )
        let rowsPerPage = Int64(BinaryPage.byteCount / BinaryHexLayout.bytesPerRow)
        let first = page.row(rowsPerPage)
        #expect(first.offset == Int64(BinaryPage.byteCount))
        #expect(first.left.count == 16)
        #expect(first.right.count == 16)
        let second = page.row(rowsPerPage + 1)
        #expect(second.left.count == 16)
        #expect(second.right.isEmpty)
        let third = page.row(rowsPerPage + 2)
        #expect(third.left.count == 8)
        #expect(
            page.row(rowsPerPage + 3) == BinaryHexRow(offset: third.offset + 16, left: [], right: [])
        )
    }

    // MARK: - Reading pages

    private func patterned(_ count: Int, seed: UInt64) -> [UInt8] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }

    private func write(_ tree: TempTree, _ name: String, _ bytes: [UInt8]) throws -> VFSPath {
        try Data(bytes).write(to: URL(fileURLWithPath: tree.path(name)))
        return tree.vfsPath(name)
    }

    @Test("pages hold each file's own bytes, short and then empty past its end")
    func readsPages() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let size = BinaryPage.byteCount
        let left = patterned(size * 2 + size / 2, seed: 1)
        let right = patterned(size + size / 2, seed: 2)
        let pair = try BinaryFilePair(left: write(tree, "a", left), right: write(tree, "b", right))
        let first = try pair.page(0)
        #expect(first.left == Array(left[..<size]))
        #expect(first.right == Array(right[..<size]))
        let second = try pair.page(1)
        #expect(second.left == Array(left[size..<(size * 2)]))
        #expect(second.right == Array(right[size...]))
        let third = try pair.page(2)
        #expect(third.left == Array(left[(size * 2)...]))
        #expect(third.right.isEmpty)
        let past = try pair.page(3)
        #expect(past.left.isEmpty)
        #expect(past.right.isEmpty)
    }

    @Test("the rows of every page add up to the files")
    func rowsCoverTheFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let left = patterned(BinaryPage.byteCount + 100, seed: 3)
        let right = patterned(BinaryPage.byteCount + 50, seed: 4)
        let pair = try BinaryFilePair(left: write(tree, "a", left), right: write(tree, "b", right))
        var leftBytes: [UInt8] = []
        var rightBytes: [UInt8] = []
        for row in 0..<BinaryHexLayout.rowCount(forByteCount: Int64(left.count)) {
            let line = try pair.page(BinaryPage.index(ofRow: row)).row(row)
            leftBytes += line.left
            rightBytes += line.right
        }
        #expect(leftBytes == left)
        #expect(rightBytes == right)
    }

    @Test("pages read at once on many threads come back right")
    func concurrentReads() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let left = patterned(BinaryPage.byteCount * 8, seed: 5)
        let right = patterned(BinaryPage.byteCount * 8, seed: 6)
        let pair = try BinaryFilePair(left: write(tree, "a", left), right: write(tree, "b", right))
        let size = BinaryPage.byteCount
        let results = LockedBox()
        DispatchQueue.concurrentPerform(iterations: 200) { round in
            let index = round % 8
            let page = try? pair.page(Int64(index))
            let ok = page?.left == Array(left[(index * size)..<((index + 1) * size)])
                && page?.right == Array(right[(index * size)..<((index + 1) * size)])
            results.note(ok)
        }
        #expect(results.allGood)
    }

    @Test("a file replaced by a rename goes on reading as the file that was compared")
    func holdsTheOpenFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try write(tree, "a", [1, 2, 3])
        let other = try write(tree, "b", [1, 2, 3])
        let pair = try BinaryFilePair(left: path, right: other)
        let replacement = try write(tree, "new", [9, 9, 9])
        #expect(rename(replacement.path, path.path) == 0)
        #expect(try pair.page(0).left == [1, 2, 3])
    }

    @Test("a file that cannot be opened throws")
    func openFailure() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let present = try write(tree, "a", [1])
        #expect(throws: VFSError.self) { try BinaryFilePair(left: tree.vfsPath("no"), right: present) }
        #expect(throws: VFSError.self) { try BinaryFilePair(left: present, right: tree.vfsPath("no")) }
    }

    // MARK: - The cache

    private func page(_ index: Int64) -> BinaryPage {
        BinaryPage(index: index, left: [UInt8(index & 0xFF)], right: [])
    }

    @Test("a held page comes back")
    func cacheHolds() {
        var cache = BinaryPageCache(capacity: 2)
        cache.insert(page(5))
        #expect(cache.page(5) == page(5))
        #expect(cache.page(6) == nil)
    }

    @Test("the page used longest ago is the one let go")
    func cacheEvictsOldest() {
        var cache = BinaryPageCache(capacity: 2)
        cache.insert(page(1))
        cache.insert(page(2))
        _ = cache.page(1)
        cache.insert(page(3))
        #expect(cache.count == 2)
        #expect(cache.page(2) == nil)
        #expect(cache.page(1) != nil)
        #expect(cache.page(3) != nil)
    }

    @Test("inserting a page already held makes no room for it")
    func cacheReinsert() {
        var cache = BinaryPageCache(capacity: 2)
        cache.insert(page(1))
        cache.insert(page(2))
        cache.insert(page(2))
        #expect(cache.count == 2)
        #expect(cache.page(1) != nil)
    }
}

/// Results gathered from `concurrentPerform`'s threads.
private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var good = true

    func note(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        good = good && value
    }

    var allGood: Bool {
        lock.lock()
        defer { lock.unlock() }
        return good
    }
}
