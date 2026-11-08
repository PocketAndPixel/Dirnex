import Foundation
import Testing

@testable import DirnexCore

/// `cmp -l` is the oracle for a byte comparison (PLAN.md §M37 Slice 1), as `git diff` is for lines:
/// it lists every byte that differs, 1-based, in octal pairs, and stops at the shorter file's end.
@Suite("BinaryComparison — against cmp")
struct BinaryComparisonCmpTests {
    /// The 0-based offsets `cmp -l` says differ.
    private func cmpOffsets(_ left: VFSPath, _ right: VFSPath) throws -> [Int64] {
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/cmp")
        process.arguments = ["-l", left.path, right.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        let text = try #require(String(bytes: data, encoding: .utf8))
        return text.split(separator: "\n").map { line in
            let field = line.split(whereSeparator: \.isWhitespace)[0]
            return (Int64(field) ?? 0) - 1
        }
    }

    private func check(_ left: VFSPath, _ right: VFSPath) throws {
        let answer = try BinaryComparison.scan(left, right)
        let offsets = try cmpOffsets(left, right)
        #expect(answer.differences.differingByteCount == Int64(offsets.count))
        var stretch = answer.differences.stretches.makeIterator()
        var current = stretch.next()
        for offset in offsets {
            while let range = current?.range, range.upperBound <= offset {
                current = stretch.next()
            }
            #expect(current?.range.contains(offset) == true, "offset \(offset) is in no stretch")
        }
        let differing = Set(offsets)
        for item in answer.differences.stretches {
            #expect(differing.contains(item.range.lowerBound))
            #expect(differing.contains(item.range.upperBound - 1))
        }
    }

    private func write(_ tree: TempTree, _ name: String, _ bytes: [UInt8]) throws -> VFSPath {
        try Data(bytes).write(to: URL(fileURLWithPath: tree.path(name)))
        return tree.vfsPath(name)
    }

    @Test("cmp agrees over random pairs of every shape")
    func randomPairs() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        var generator = SeededGenerator(seed: 2026)
        for round in 0..<40 {
            // Sizes around the page and the read chunk's multiples, where an off-by-one would show.
            let size = [0, 1, 15, 16, 17, 4096, 65535, 65536, 65537, 200_000]
                .randomElement(using: &generator) ?? 0
            let left = (0..<size).map { _ in UInt8.random(in: 0...255, using: &generator) }
            var right = left
            for _ in 0..<Int.random(in: 0...60, using: &generator) where size > 0 {
                right[Int.random(in: 0..<size, using: &generator)] &+= 1
            }
            switch round % 4 {
            case 1: right += (0..<Int.random(in: 1...300, using: &generator)).map { UInt8($0 & 0xFF) }
            case 2: right.removeLast(min(right.count, Int.random(in: 1...300, using: &generator)))
            default: break
            }
            try check(write(tree, "l\(round)", left), write(tree, "r\(round)", right))
        }
    }

    @Test("cmp agrees across a read chunk's boundary")
    func acrossAChunkBoundary() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let chunk = BinaryComparison.defaultChunkSize
        let left = [UInt8](repeating: 0x41, count: chunk * 2)
        var right = left
        right[chunk - 1] = 0
        right[chunk] = 0
        try check(write(tree, "a", left), write(tree, "b", right))
    }

    @Test("cmp agrees on an inserted run, where nearly every byte differs")
    func insertion() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        var generator = SeededGenerator(seed: 7)
        let left = (0..<300_000).map { _ in UInt8.random(in: 0...255, using: &generator) }
        var right = left
        right.insert(contentsOf: [1, 2, 3], at: 1000)
        try check(write(tree, "a", left), write(tree, "b", right))
    }

    @Test("cmp agrees on real programs from this Mac")
    func realBinaries() throws {
        try check(.local("/bin/ls"), .local("/bin/cp"))
        try check(.local("/bin/cat"), .local("/bin/cat"))
    }

    @Test("a list at its bound still covers every byte cmp lists")
    func boundedListCoversCmp() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let left = [UInt8](repeating: 0, count: 40000)
        var right = left
        for offset in stride(from: 0, to: 40000, by: 19) {
            right[offset] = 1
        }
        var list = BinaryDifferenceList(capacity: 32)
        left.withUnsafeBytes { leftBytes in
            right.withUnsafeBytes { rightBytes in
                list.consume(leftBytes, rightBytes, at: 0)
            }
        }
        let offsets = try cmpOffsets(write(tree, "a", left), write(tree, "b", right))
        #expect(list.differingByteCount == Int64(offsets.count))
        for offset in offsets {
            #expect(list.stretches.contains { $0.range.contains(offset) })
        }
    }
}
