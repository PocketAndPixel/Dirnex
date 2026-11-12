import Foundation
import Testing

@testable import DirnexCore

/// What the byte view's keys and banner ask of a comparison (PLAN.md §M37 Slice 1): stepping from
/// one change to the next, and the shape an insertion leaves.
@Suite("BinaryComparison — stepping and shape")
struct BinaryComparisonSteppingTests {
    private func write(_ tree: TempTree, _ name: String, _ bytes: [UInt8]) throws -> VFSPath {
        try Data(bytes).write(to: URL(fileURLWithPath: tree.path(name)))
        return tree.vfsPath(name)
    }

    private func comparison(
        leftByteSize: Int64 = 1000,
        rightByteSize: Int64 = 1000,
        differing offsets: [Int]
    ) -> BinaryComparison {
        let count = Int(min(leftByteSize, rightByteSize))
        var list = BinaryDifferenceList()
        let left = [UInt8](repeating: 0, count: count)
        var right = left
        for offset in offsets {
            right[offset] = 1
        }
        left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes in
                list.consume(leftBytes, rightBytes, at: 0)
            }
        }
        return BinaryComparison(
            leftByteSize: leftByteSize,
            rightByteSize: rightByteSize,
            differences: list,
            scannedByteCount: Int64(count)
        )
    }

    // MARK: - Moving between changes

    @Test("next and previous step over every change, the tail last")
    func stepping() {
        let answer = comparison(leftByteSize: 1000, rightByteSize: 1010, differing: [100, 500])
        #expect(answer.change(after: -1) == 100..<101)
        #expect(answer.change(after: 100) == 500..<501)
        #expect(answer.change(after: 500) == 1000..<1010)
        #expect(answer.change(after: 1000) == nil)
        #expect(answer.change(before: 1000) == 500..<501)
        #expect(answer.change(before: 500) == 100..<101)
        #expect(answer.change(before: 100) == nil)
    }

    @Test("from inside a stretch, previous goes to the one before it", arguments: [101, 110])
    func stepsOutOfAStretch(offset: Int64) {
        let answer = comparison(differing: [50, 100, 110])
        #expect(answer.change(before: offset) == 100..<111)
    }

    @Test("a change is found by any offset inside it")
    func changeIndex() {
        let answer = comparison(leftByteSize: 1000, rightByteSize: 1010, differing: [100, 110, 500])
        #expect(answer.changeIndex(containing: 99) == nil)
        #expect(answer.changeIndex(containing: 100) == 0)
        #expect(answer.changeIndex(containing: 105) == 0)
        #expect(answer.changeIndex(containing: 110) == 0)
        #expect(answer.changeIndex(containing: 111) == nil)
        #expect(answer.changeIndex(containing: 500) == 1)
        #expect(answer.changeIndex(containing: 1009) == 2)
        #expect(answer.changeIndex(containing: 1010) == nil)
    }

    @Test("a stretch that ends where the tail starts stays apart from it")
    func stretchTouchingTheTail() {
        let answer = comparison(leftByteSize: 1000, rightByteSize: 1010, differing: [999])
        #expect(answer.changes == [999..<1000, 1000..<1010])
        #expect(answer.changeIndex(containing: 999) == 0)
        #expect(answer.changeIndex(containing: 1000) == 1)
    }

    @Test("a change's rows run from the row of its first byte to the row of its last")
    func changeRows() {
        let answer = comparison(leftByteSize: 1000, rightByteSize: 1010, differing: [15, 16, 500])
        #expect(answer.changeRows == [0..<2, 31..<32, 62..<64])
    }

    @Test("how far a scan has got is a percentage of what the two sides share")
    func percentScanned() {
        let list = BinaryDifferenceList()
        func percent(_ scanned: Int64, of size: Int64) -> Int {
            BinaryComparison(
                leftByteSize: size,
                rightByteSize: size,
                differences: list,
                scannedByteCount: scanned
            ).percentScanned
        }
        #expect(percent(0, of: 1000) == 0)
        #expect(percent(450, of: 1000) == 45)
        #expect(percent(1000, of: 1000) == 100)
        #expect(percent(0, of: 0) == 100)
        #expect(percent(1 << 62, of: 1 << 62) == 100)
    }

    @Test("the binary searches agree with a walk", arguments: [1, 2, 3, 8, 40])
    func searchesAgreeWithWalk(step: Int) {
        var generator = SeededGenerator(seed: UInt64(step))
        let offsets = stride(from: step, to: 3000, by: step * 40).map { $0 + Int.random(
            in: 0..<step,
            using: &generator
        ) }
        let answer = comparison(leftByteSize: 3000, rightByteSize: 3010, differing: offsets)
        let all = answer.changes
        for offset in stride(from: Int64(-1), to: 3020, by: 7) {
            #expect(answer.change(after: offset) == all.first { $0.lowerBound > offset })
            #expect(answer.change(before: offset) == all.last { $0.lowerBound < offset })
            #expect(answer.changeIndex(containing: offset) == all.firstIndex { $0.contains(offset) })
        }
    }

    // MARK: - What an insertion looks like

    @Test("bytes inserted near the start read as one dense stretch to the end")
    func insertionIsDense() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        var generator = SeededGenerator(seed: 11)
        let left = (0..<(512 * 1024)).map { _ in UInt8.random(in: 0...255, using: &generator) }
        var right = left
        right.insert(
            contentsOf: (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) },
            at: 4096
        )
        let answer = try BinaryComparison.scan(write(tree, "a", left), write(tree, "b", right))
        let dense = try #require(answer.largestDenseStretch())
        #expect(dense.range.lowerBound >= 4096)
        #expect(dense.range.lowerBound < 4096 + 32)
        #expect(dense.range.upperBound >= 512 * 1024 - 32)
    }

    @Test("scattered patches are nothing like an insertion")
    func patchesAreNotDense() {
        let offsets = Array(stride(from: 0, to: 200_000, by: 5000))
        #expect(comparison(leftByteSize: 200_000, rightByteSize: 200_000, differing: offsets)
            .largestDenseStretch() == nil)
    }

    @Test("a dense run shorter than the minimum is not reported")
    func shortDenseRun() {
        let answer = comparison(differing: Array(100..<200))
        #expect(answer.largestDenseStretch(minimumLength: 101) == nil)
        #expect(answer.largestDenseStretch(minimumLength: 100)?.range == 100..<200)
    }

    @Test("a stretch that is mostly equal bytes is not dense")
    func sparseLongStretch() {
        // One differing byte every 16 joins into a single stretch, one sixteenth of it differing.
        let offsets = Array(stride(from: 0, to: 1000, by: 16))
        let answer = comparison(differing: offsets)
        #expect(answer.differences.stretches.count == 1)
        #expect(answer.largestDenseStretch(minimumLength: 10) == nil)
    }

    @Test("the largest of several dense stretches is the one named")
    func largestOfSeveral() {
        let answer = comparison(differing: Array(0..<100) + Array(400..<700))
        #expect(answer.largestDenseStretch(minimumLength: 50)?.range == 400..<700)
    }
}
