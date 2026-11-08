import Foundation
import Testing

@testable import DirnexCore

/// What a byte comparison turns away (PLAN.md §M37 Slice 1), and the one read it must not make: an
/// evicted cloud placeholder, driven through `ComparisonSubject` as `ByteComparator`'s are, since
/// `SF_DATALESS` cannot be set on a test file.
@Suite("BinaryComparison — refusals")
struct BinaryComparisonRefusalTests {
    private func write(_ tree: TempTree, _ name: String, _ bytes: [UInt8]) throws -> VFSPath {
        try Data(bytes).write(to: URL(fileURLWithPath: tree.path(name)))
        return tree.vfsPath(name)
    }

    private func subject(
        _ path: VFSPath,
        byteSize: Int64,
        isDataless: Bool = false
    ) -> ComparisonSubject {
        ComparisonSubject(
            path: path,
            isRegularFile: true,
            byteSize: byteSize,
            isDataless: isDataless
        )
    }

    @Test("a path that is not local is refused")
    func refusesRemote() {
        let remote = VFSPath(backend: .archive(forArchiveAt: "/tmp/x.zip"), path: "/a")
        #expect {
            try BinaryComparison.scan(remote, .local("/tmp/b"))
        } throws: { error in
            guard case let .unsupported(reason) = error as? VFSError else { return false }
            return reason == .contentComparisonNeedsLocalFiles
        }
    }

    @Test("a folder is refused")
    func refusesFolder() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("d")
        let file = try write(tree, "a", [1])
        #expect {
            try BinaryComparison.scan(tree.vfsPath("d"), file)
        } throws: { error in
            guard case let .unsupported(reason) = error as? VFSError else { return false }
            return reason == .contentComparisonNeedsRegularFile
        }
    }

    @Test("a missing file throws rather than reading as empty")
    func refusesMissing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try write(tree, "a", [1])
        #expect(throws: VFSError.self) {
            try BinaryComparison.scan(file, tree.vfsPath("nope"))
        }
    }

    @Test("an evicted placeholder is refused by name rather than read")
    func refusesDataless() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let left = try write(tree, "a", [1, 2])
        let right = try write(tree, "b", [1, 3])
        #expect {
            try BinaryComparison.scan(
                subject(left, byteSize: 2),
                subject(right, byteSize: 2, isDataless: true),
                chunkSize: 16,
                allowDataless: false,
                reportEvery: 1 << 20,
                report: { _ in },
                isCancelled: { false }
            )
        } throws: { error in
            guard case let .unsupported(reason) = error as? VFSError,
                  case let .contentComparisonWouldDownload(name) = reason else { return false }
            return name == "b"
        }
    }

    @Test("a placeholder the gesture already agreed to fetch is read")
    func allowsDatalessWhenAgreed() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let left = try write(tree, "a", [1, 2])
        let right = try write(tree, "b", [1, 3])
        let answer = try BinaryComparison.scan(
            subject(left, byteSize: 2),
            subject(right, byteSize: 2, isDataless: true),
            chunkSize: 16,
            allowDataless: true,
            reportEvery: 1 << 20,
            report: { _ in },
            isCancelled: { false }
        )
        #expect(answer.changes == [1..<2])
    }

    @Test("sizes alone answer without reading a placeholder, as ByteComparator's do")
    func emptyAgainstPlaceholderReadsNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let left = try write(tree, "a", [])
        let right = try write(tree, "b", [1, 3])
        let answer = try BinaryComparison.scan(
            subject(left, byteSize: 0),
            subject(right, byteSize: 2, isDataless: true),
            chunkSize: 16,
            allowDataless: false,
            reportEvery: 1 << 20,
            report: { _ in },
            isCancelled: { false }
        )
        #expect(answer.tail == 0..<2)
    }
}
