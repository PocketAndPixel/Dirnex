import Foundation
import Testing

@testable import DirnexCore

/// The stretches a byte comparison steps through (PLAN.md §M37 Slice 1): what joins, what stays
/// apart, and that a list at its bound loses resolution rather than a difference.
@Suite("BinaryDifferenceList")
struct BinaryDifferenceListTests {
    private func list(
        _ left: [UInt8],
        _ right: [UInt8],
        gap: Int64 = 16,
        capacity: Int = BinaryDifferenceList.defaultCapacity,
        chunk: Int? = nil
    ) -> BinaryDifferenceList {
        var list = BinaryDifferenceList(gap: gap, capacity: capacity)
        let count = min(left.count, right.count)
        var start = 0
        while start < count {
            let end = min(start + (chunk ?? count), count)
            left[start..<end].withUnsafeBytes { leftBytes in
                right[start..<end].withUnsafeBytes { rightBytes in
                    list.consume(leftBytes, rightBytes, at: Int64(start))
                }
            }
            start = end
        }
        return list
    }

    /// `left` with the bytes at `offsets` flipped.
    private func flipped(_ left: [UInt8], at offsets: [Int]) -> [UInt8] {
        var right = left
        for offset in offsets {
            right[offset] ^= 0xFF
        }
        return right
    }

    private func ranges(_ list: BinaryDifferenceList) -> [Range<Int64>] {
        list.stretches.map(\.range)
    }

    /// Every promise the list makes, against the offsets that really differ.
    private func expectHolds(_ list: BinaryDifferenceList, differing offsets: [Int]) {
        let differing = Set(offsets.map(Int64.init))
        #expect(list.differingByteCount == Int64(offsets.count))
        #expect(list.stretches.reduce(0) { $0 + $1.differingByteCount } == Int64(offsets.count))
        #expect(list.stretches.count <= list.capacity)
        for offset in differing {
            #expect(list.stretches.contains { $0.range.contains(offset) })
        }
        for stretch in list.stretches {
            #expect(differing.contains(stretch.range.lowerBound))
            #expect(differing.contains(stretch.range.upperBound - 1))
        }
        for (first, second) in zip(list.stretches, list.stretches.dropFirst()) {
            #expect(second.range.lowerBound - first.range.upperBound >= list.gap)
        }
    }

    @Test("identical bytes leave no stretch, and no count")
    func identical() {
        let list = list([1, 2, 3], [1, 2, 3])
        #expect(list.stretches.isEmpty)
        #expect(list.differingByteCount == 0)
    }

    @Test("empty buffers are nothing to compare")
    func empty() {
        #expect(list([], []).stretches.isEmpty)
        #expect(list([1, 2], []).stretches.isEmpty)
    }

    @Test("a single differing byte is a stretch of one")
    func singleByte() {
        let left = [UInt8](repeating: 7, count: 64)
        #expect(ranges(list(left, flipped(left, at: [40]))) == [40..<41])
    }

    @Test("only the length both buffers share is compared")
    func shorterOfTheTwo() {
        var list = BinaryDifferenceList()
        let left: [UInt8] = [1, 2, 3, 4]
        let right: [UInt8] = [1, 9]
        left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes in
                list.consume(leftBytes, rightBytes, at: 0)
            }
        }
        #expect(ranges(list) == [1..<2])
    }

    @Test("fifteen equal bytes between two differences join them, on a row of sixteen")
    func joinsBelowTheGap() {
        let left = [UInt8](repeating: 0, count: 64)
        #expect(ranges(list(left, flipped(left, at: [0, 16]))) == [0..<17])
    }

    @Test("sixteen equal bytes between two differences keep them apart")
    func splitsAtTheGap() {
        let left = [UInt8](repeating: 0, count: 64)
        #expect(ranges(list(left, flipped(left, at: [0, 17]))) == [0..<1, 17..<18])
    }

    @Test("a stretch keeps how many of its bytes differ, not how long it is")
    func stretchCountsDifferingBytes() {
        let left = [UInt8](repeating: 0, count: 64)
        let stretch = list(left, flipped(left, at: [2, 10, 20])).stretches
        #expect(stretch == [.init(range: 2..<21, differingByteCount: 3)])
    }

    @Test("where the buffers were cut changes nothing", arguments: [1, 3, 15, 16, 17, 64, 4096])
    func chunkingIsInvisible(chunk: Int) {
        var generator = SeededGenerator(seed: 37)
        let left = (0..<3000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        let offsets = (0..<3000).filter { _ in Int.random(in: 0..<40, using: &generator) == 0 }
        let right = flipped(left, at: offsets)
        #expect(list(left, right, chunk: chunk) == list(left, right))
    }

    @Test("a stretch runs across a chunk boundary")
    func spansChunks() {
        let left = [UInt8](repeating: 0, count: 64)
        #expect(ranges(list(left, flipped(left, at: [15, 16, 17]), chunk: 16)) == [15..<18])
    }

    @Test("offsets are the caller's, past 4 GiB as well")
    func largeOffsets() {
        var list = BinaryDifferenceList()
        let left: [UInt8] = [1, 2]
        let right: [UInt8] = [1, 3]
        left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes in
                list.consume(leftBytes, rightBytes, at: 0x1_0000_0000)
            }
        }
        #expect(ranges(list) == [0x1_0000_0001..<0x1_0000_0002])
    }

    @Test("at its bound the list joins stretches, and every promise still holds")
    func boundKeepsEveryDifference() {
        // One differing byte every 20 bytes: 16 equal bytes would split them, 19 do, so each is a
        // stretch of its own until the list has to give way.
        let left = [UInt8](repeating: 1, count: 20000)
        let offsets = Array(stride(from: 0, to: 20000, by: 20))
        let list = list(left, flipped(left, at: offsets), capacity: 64)
        #expect(list.gap > 16)
        #expect(list.stretches.count <= 64)
        #expect(list.differingByteCount == 1000)
        expectHolds(list, differing: offsets)
    }

    @Test("every promise holds over random pairs, at every bound", arguments: [2, 3, 8, 50, 100_000])
    func promisesHold(capacity: Int) {
        var generator = SeededGenerator(seed: UInt64(capacity))
        for _ in 0..<60 {
            let count = Int.random(in: 1...2000, using: &generator)
            let left = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
            let density = Int.random(in: 1...200, using: &generator)
            let offsets = (0..<count).filter { _ in Int.random(in: 0..<density, using: &generator) == 0 }
            let chunk = Int.random(in: 1...count, using: &generator)
            let list = list(left, flipped(left, at: offsets), capacity: capacity, chunk: chunk)
            expectHolds(list, differing: offsets)
        }
    }
}
