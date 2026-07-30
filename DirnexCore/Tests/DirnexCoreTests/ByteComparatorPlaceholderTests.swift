import Foundation
import Testing

@testable import DirnexCore

/// The placeholder half of `ByteComparator` (PLAN.md §M9 "dataless placeholder awareness"): what
/// the comparator does when a side's bytes are not on this disk.
///
/// Its own suite because these cases are driven through `ComparisonSubject` rather than through a
/// real file — `SF_DATALESS` cannot be produced in a test, so the decision half is exercised
/// directly — and because `ByteComparatorTests` was already at its type-body budget.
@Suite("ByteComparator — evicted cloud placeholders")
struct ByteComparatorPlaceholderTests {
    // Probed on macOS 26: `chflags` returns success for `SF_DATALESS` and the kernel silently drops
    // the flag — it belongs to the file provider, not to the file's owner — so no test can make a
    // real placeholder. The paths below are real files all the same, so every case that *doesn't*
    // refuse still reads their bytes and the answer is a genuine comparison.

    /// A subject describing a real file, with the placeholder flag whatever the test needs.
    private func subject(
        _ tree: TempTree,
        _ name: String,
        byteSize: Int64,
        isDataless: Bool
    ) -> ComparisonSubject {
        ComparisonSubject(
            path: tree.vfsPath(name),
            isRegularFile: true,
            byteSize: byteSize,
            isDataless: isDataless
        )
    }

    @Test("a dataless side refuses the comparison instead of downloading it")
    func datalessRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "hello world")
        try tree.writeFile("b", contents: "hello world")

        #expect {
            try ByteComparator.equal(
                subject(tree, "a", byteSize: 11, isDataless: true),
                subject(tree, "b", byteSize: 11, isDataless: false),
                chunkSize: 4,
                allowDataless: false,
                isCancelled: { false }
            )
        } throws: { error in
            guard case let .unsupported(reason) = error as? VFSError,
                  case let .contentComparisonWouldDownload(name) = reason else {
                return false
            }
            return name == "a"
        }
    }

    @Test("the refusal names the dataless side, whichever one it is")
    func datalessRefusalNamesTheRightSide() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "hello world")
        try tree.writeFile("b", contents: "hello world")

        #expect {
            try ByteComparator.equal(
                subject(tree, "a", byteSize: 11, isDataless: false),
                subject(tree, "b", byteSize: 11, isDataless: true),
                chunkSize: 4,
                allowDataless: false,
                isCancelled: { false }
            )
        } throws: { error in
            guard case let .unsupported(reason) = error as? VFSError,
                  case let .contentComparisonWouldDownload(name) = reason else {
                return false
            }
            return name == "b"
        }
    }

    @Test("allowDataless reads through a placeholder, for a caller that already asked")
    func datalessAllowed() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "hello world")
        try tree.writeFile("b", contents: "hello world")

        let equal = try ByteComparator.equal(
            subject(tree, "a", byteSize: 11, isDataless: true),
            subject(tree, "b", byteSize: 11, isDataless: true),
            chunkSize: 4,
            allowDataless: true,
            isCancelled: { false }
        )
        #expect(equal)
    }

    /// The guard exists to stop a *read*, so an answer that costs no read must still be given: a
    /// placeholder carries its real size, and refusing a free verdict would abort a content sync
    /// over a pair it had already classified.
    @Test("a size mismatch answers before the placeholder guard, since it reads nothing")
    func datalessSizeMismatchStillAnswers() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", contents: "short")
        try tree.writeFile("b", contents: "a much longer string")

        let equal = try ByteComparator.equal(
            subject(tree, "a", byteSize: 5, isDataless: true),
            subject(tree, "b", byteSize: 20, isDataless: true),
            chunkSize: 4,
            allowDataless: false,
            isCancelled: { false }
        )
        #expect(!equal)
    }

    @Test("two empty placeholders are equal without a read")
    func datalessEmptyFilesStillAnswer() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", bytes: 0)
        try tree.writeFile("b", bytes: 0)

        let equal = try ByteComparator.equal(
            subject(tree, "a", byteSize: 0, isDataless: true),
            subject(tree, "b", byteSize: 0, isDataless: true),
            chunkSize: 4,
            allowDataless: false,
            isCancelled: { false }
        )
        #expect(equal)
    }

    /// `tooLargeToScan` reads nothing either, so it is not a comparison that would download
    /// anything — the app makes the *diff tool's* read safe separately.
    @Test("the byte-limit gate answers before the placeholder guard")
    func datalessOverLimitIsReportedUnscanned() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", bytes: 100)
        try tree.writeFile("b", bytes: 100)

        let outcome = try ByteComparator.prescan(
            subject(tree, "a", byteSize: 100, isDataless: true),
            subject(tree, "b", byteSize: 100, isDataless: true),
            byteLimit: 64,
            chunkSize: 4,
            allowDataless: false,
            isCancelled: { false }
        )
        #expect(outcome == .tooLargeToScan(largestByteSize: 100))
    }

    @Test("prescan within the limit refuses a placeholder")
    func prescanDatalessRefused() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", bytes: 32)
        try tree.writeFile("b", bytes: 32)

        #expect {
            try ByteComparator.prescan(
                subject(tree, "a", byteSize: 32, isDataless: true),
                subject(tree, "b", byteSize: 32, isDataless: false),
                byteLimit: 64,
                chunkSize: 4,
                allowDataless: false,
                isCancelled: { false }
            )
        } throws: { error in
            guard case let .unsupported(reason) = error as? VFSError,
                  case .contentComparisonWouldDownload = reason else { return false }
            return true
        }
    }

    /// A non-regular side is refused before anything else, placeholder or not — the claim that
    /// survived moving the type check off `FileManager.attributesOfItem` and onto a raw `lstat`.
    @Test("a non-regular side outranks the placeholder guard")
    func nonRegularOutranksDataless() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("dir")
        try tree.writeFile("file", contents: "x")

        #expect {
            try ByteComparator.equal(
                ComparisonSubject(
                    path: tree.vfsPath("dir"),
                    isRegularFile: false,
                    byteSize: 1,
                    isDataless: true
                ),
                subject(tree, "file", byteSize: 1, isDataless: false),
                chunkSize: 4,
                allowDataless: false,
                isCancelled: { false }
            )
        } throws: { error in
            guard case let .unsupported(reason) = error as? VFSError,
                  case .contentComparisonNeedsRegularFile = reason else { return false }
            return true
        }
    }

    // MARK: - The `lstat` the guards now share

    @Test("a real file's subject carries its type, size and a clear placeholder flag")
    func subjectReadsRealFacts() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a", bytes: 37)
        try tree.makeDir("dir")

        let file = try ByteComparator.subject(tree.vfsPath("a"))
        #expect(file.isRegularFile)
        #expect(file.byteSize == 37)
        #expect(!file.isDataless) // nothing on a temp disk is a cloud placeholder

        let directory = try ByteComparator.subject(tree.vfsPath("dir"))
        #expect(!directory.isRegularFile)
    }

    @Test("a subject for a path that isn't there reports the errno, not a fabricated size")
    func subjectOfMissingPathThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        #expect(throws: VFSError.self) {
            try ByteComparator.subject(tree.vfsPath("nope"))
        }
    }
}
