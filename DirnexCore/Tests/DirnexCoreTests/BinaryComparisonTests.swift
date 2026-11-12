import Foundation
import Testing

@testable import DirnexCore

/// Two real files compared at the same offset (PLAN.md §M37 Slice 1), and what the window asks of
/// the answer.
@Suite("BinaryComparison")
struct BinaryComparisonTests {
    private func write(_ tree: TempTree, _ name: String, _ bytes: [UInt8]) throws -> VFSPath {
        try Data(bytes).write(to: URL(fileURLWithPath: tree.path(name)))
        return tree.vfsPath(name)
    }

    private func subject(
        _ path: VFSPath,
        byteSize: Int64,
        isDataless: Bool = false,
        isRegularFile: Bool = true
    ) -> ComparisonSubject {
        ComparisonSubject(
            path: path,
            isRegularFile: isRegularFile,
            byteSize: byteSize,
            isDataless: isDataless
        )
    }

    // MARK: - Files

    @Test("two identical files say so")
    func identicalFiles() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let bytes = [UInt8](repeating: 9, count: 5000)
        let answer = try BinaryComparison.scan(write(tree, "a", bytes), write(tree, "b", bytes))
        #expect(answer.isIdentical)
        #expect(answer.isFinished)
        #expect(answer.changes.isEmpty)
    }

    @Test("two empty files are identical")
    func emptyFiles() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let answer = try BinaryComparison.scan(write(tree, "a", []), write(tree, "b", []))
        #expect(answer.isIdentical)
        #expect(answer.tail == nil)
    }

    @Test("differences come back at their own offsets")
    func findsDifferences() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        var right = [UInt8](repeating: 0, count: 5000)
        right[100] = 1
        right[4999] = 2
        let answer = try BinaryComparison.scan(
            write(tree, "a", [UInt8](repeating: 0, count: 5000)),
            write(tree, "b", right)
        )
        #expect(answer.changes == [100..<101, 4999..<5000])
        #expect(answer.differences.differingByteCount == 2)
        #expect(!answer.isIdentical)
    }

    @Test("the bytes past the shorter file are the last change, and name their side")
    func tailOnTheRight() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let short = [UInt8](repeating: 3, count: 100)
        let answer = try BinaryComparison.scan(
            write(tree, "a", short),
            write(tree, "b", short + [1, 2, 3])
        )
        #expect(answer.tail == 100..<103)
        #expect(answer.longerSide == .right)
        #expect(answer.commonByteCount == 100)
        #expect(answer.changes == [100..<103])
        #expect(answer.differences.differingByteCount == 0)
        #expect(!answer.isIdentical)
    }

    @Test("the longer file can be the left one")
    func tailOnTheLeft() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let short = [UInt8](repeating: 3, count: 100)
        let answer = try BinaryComparison.scan(
            write(tree, "a", short + [1]),
            write(tree, "b", short)
        )
        #expect(answer.longerSide == .left)
        #expect(answer.tail == 100..<101)
    }

    @Test("an empty file against a full one is all tail, and reads no bytes")
    func emptyAgainstFull() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let answer = try BinaryComparison.scan(write(tree, "a", []), write(tree, "b", [1, 2]))
        #expect(answer.tail == 0..<2)
        #expect(answer.changes == [0..<2])
    }

    @Test("the chunk size is invisible in the answer", arguments: [1, 7, 16, 4096, 1 << 20])
    func chunkSizes(chunkSize: Int) throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        var generator = SeededGenerator(seed: 5)
        let left = (0..<9000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        var right = left
        for _ in 0..<40 {
            right[Int.random(in: 0..<9000, using: &generator)] &+= 1
        }
        let leftPath = try write(tree, "a", left)
        let rightPath = try write(tree, "b", right)
        let whole = try BinaryComparison.scan(leftPath, rightPath)
        let chunked = try BinaryComparison.scan(leftPath, rightPath, chunkSize: chunkSize)
        #expect(chunked == whole)
    }

    @Test("a pair already open gives the answer the two paths give")
    func scanOfAnOpenPair() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        var right = [UInt8](repeating: 0, count: 3000)
        right[1500] = 1
        let leftPath = try write(tree, "a", [UInt8](repeating: 0, count: 3000) + [5])
        let rightPath = try write(tree, "b", right)
        let pair = try BinaryFilePair(left: leftPath, right: rightPath)
        #expect(try BinaryComparison.scan(pair) == BinaryComparison.scan(leftPath, rightPath))
    }

    @Test("a scan of an open pair goes by the sizes it was opened at")
    func scanOfAnOpenPairKeepsItsSizes() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let bytes = [UInt8](repeating: 1, count: 100)
        let leftPath = try write(tree, "a", bytes)
        let rightPath = try write(tree, "b", bytes)
        let pair = try BinaryFilePair(left: leftPath, right: rightPath)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: leftPath.path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([9, 9]))
        try handle.close()
        let answer = try BinaryComparison.scan(pair)
        #expect(answer.leftByteSize == 100)
        #expect(answer.isIdentical)
    }

    // MARK: - While it runs

    @Test("Stop throws, before and during the scan")
    func cancellation() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let bytes = [UInt8](repeating: 1, count: 4096)
        let left = try write(tree, "a", bytes)
        let right = try write(tree, "b", bytes)
        #expect(throws: CancellationError.self) {
            try BinaryComparison.scan(left, right, chunkSize: 16, isCancelled: { true })
        }
        var calls = 0
        #expect(throws: CancellationError.self) {
            try BinaryComparison.scan(left, right, chunkSize: 16, isCancelled: {
                calls += 1
                return calls > 10
            })
        }
        #expect(calls == 11)
    }

    @Test("a running scan reports what it has so far, and never the finished answer")
    func reports() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        var right = [UInt8](repeating: 0, count: 1000)
        for offset in stride(from: 50, to: 1000, by: 100) {
            right[offset] = 1
        }
        let leftPath = try write(tree, "a", [UInt8](repeating: 0, count: 1000))
        let rightPath = try write(tree, "b", right)
        var reports: [BinaryComparison] = []
        let answer = try BinaryComparison.scan(
            subject(leftPath, byteSize: 1000),
            subject(rightPath, byteSize: 1000),
            chunkSize: 64,
            allowDataless: false,
            reportEvery: 256,
            report: { reports.append($0) },
            isCancelled: { false }
        )
        #expect(reports.map(\.scannedByteCount) == [256, 512, 768])
        #expect(reports.allSatisfy { !$0.isFinished })
        #expect(answer.isFinished)
        #expect(reports.map(\.differences.stretches.count) == [3, 5, 8])
    }

    @Test("a file that shrank says the rest was not compared")
    func shrankUnderTheScan() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let bytes = [UInt8](repeating: 1, count: 100)
        let answer = try BinaryComparison.scan(
            subject(write(tree, "a", bytes), byteSize: 200),
            subject(write(tree, "b", bytes), byteSize: 200),
            chunkSize: 16,
            allowDataless: false,
            reportEvery: 1 << 20,
            report: { _ in },
            isCancelled: { false }
        )
        #expect(answer.endedEarly)
        #expect(answer.scannedByteCount == 100)
        #expect(answer.isFinished)
        #expect(!answer.isIdentical)
    }

    @Test("a scan ending exactly on a report's boundary does not report the finished answer")
    func noReportAtTheEnd() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let bytes = [UInt8](repeating: 0, count: 768)
        let leftPath = try write(tree, "a", bytes)
        let rightPath = try write(tree, "b", bytes)
        var reports: [Int64] = []
        _ = try BinaryComparison.scan(
            subject(leftPath, byteSize: 768),
            subject(rightPath, byteSize: 768),
            chunkSize: 64,
            allowDataless: false,
            reportEvery: 256,
            report: { reports.append($0.scannedByteCount) },
            isCancelled: { false }
        )
        #expect(reports == [256, 512])
    }

    @Test("a file that shrank to a chunk's edge says so too", arguments: [Int64(96), 112])
    func shrankToAChunkBoundary(actual: Int64) throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let bytes = [UInt8](repeating: 1, count: Int(actual))
        let answer = try BinaryComparison.scan(
            subject(write(tree, "a", bytes), byteSize: 200),
            subject(write(tree, "b", bytes), byteSize: 200),
            chunkSize: 16,
            allowDataless: false,
            reportEvery: 1 << 20,
            report: { _ in },
            isCancelled: { false }
        )
        #expect(answer.endedEarly)
        #expect(answer.scannedByteCount == actual)
        #expect(!answer.isIdentical)
    }
}
