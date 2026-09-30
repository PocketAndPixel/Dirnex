import Foundation
import Testing

@testable import DirnexCore

/// The two-phase content scan: one walk, the pairs whose bytes decide it, and the re-answer once
/// those bytes are on this disk (PLAN.md §M25 Slice 5d).
@Suite("DirectorySync — comparing contents in two phases")
struct DirectorySyncContentTests {
    private let backend = LocalBackend()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let sftp = VFSBackendID.sftp(SFTPLocation(host: "example.test", username: "oleg"))

    private func twoRoots() throws -> TempTree {
        let tree = try TempTree()
        try tree.makeDir("L")
        try tree.makeDir("R")
        return tree
    }

    private func survey(_ tree: TempTree) throws -> [SyncEntry] {
        try DirectorySync.survey(
            left: tree.vfsPath("L"),
            right: tree.vfsPath("R"),
            leftBackend: backend,
            rightBackend: backend
        )
    }

    // MARK: - Phase one

    /// The survey's two properties, and both are preconditions of the phase that follows rather
    /// than preferences: it classifies by **size**, which reads nothing and consults no clock, and
    /// it keeps the **identical** rows, which are precisely the pairs a content scan has to read.
    /// A survey that dropped them would hand the content phase a shorter list and say nothing.
    @Test("the survey keeps the rows a content scan will need")
    func surveyKeepsIdenticalRows() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/same-size.txt", contents: "aaaaa")
        try tree.writeFile("R/same-size.txt", contents: "bbbbb")
        try tree.writeFile("L/differs.txt", contents: "a longer body")
        try tree.writeFile("R/differs.txt", contents: "short")
        try tree.writeFile("L/only-left.txt", contents: "x")

        let surveyed = try survey(tree)
        #expect(surveyed.map(\.relativePath) == ["differs.txt", "only-left.txt", "same-size.txt"])
        let byPath = Dictionary(uniqueKeysWithValues: surveyed.map { ($0.relativePath, $0.status) })
        // Same length, different bytes: a size scan calls this identical, which is exactly why it
        // has to survive into phase two.
        #expect(byPath["same-size.txt"] == .identical)
        #expect(byPath["differs.txt"] == .differ)
        #expect(byPath["only-left.txt"] == .leftOnly)
        // The narrowness half: an ordinary comparison still drops it, so "keep everything" belongs
        // to the survey rather than having leaked into the engine.
        let ordinary = try DirectorySync.compare(
            left: tree.vfsPath("L"),
            right: tree.vfsPath("R"),
            leftBackend: backend,
            rightBackend: backend,
            comparison: .size
        )
        #expect(!ordinary.contains { $0.relativePath == "same-size.txt" })
    }

    /// What the gesture pays for, and nothing else: both sides present, both regular files, and the
    /// same size. Everything else is already decided — a size mismatch is an answer, a one-sided row
    /// has nothing to compare against, and a link or a directory has no contents to read.
    @Test("the candidates are the same-size regular-file pairs and nothing else")
    func candidatesAreSameSizeFilePairs() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/pair.txt", contents: "aaaaa")
        try tree.writeFile("R/pair.txt", contents: "bbbbb")
        try tree.writeFile("L/sizes-differ.txt", contents: "a longer body")
        try tree.writeFile("R/sizes-differ.txt", contents: "short")
        try tree.writeFile("L/only-left.txt", contents: "x")
        try tree.writeFile("R/only-right.txt", contents: "x")
        try tree.symlink("L/link", to: "/etc/hosts")
        try tree.symlink("R/link", to: "/etc/hosts")
        try tree.makeDir("L/clash")
        try tree.writeFile("R/clash", contents: "not a folder")

        let candidates = DirectorySync.contentCandidates(in: try survey(tree))
        #expect(candidates.map(\.relativePath) == ["pair.txt"])
    }

    /// A directory present on both sides is descended into and produces no row at all, so it cannot
    /// reach the candidate set — asserted rather than assumed, because a folder is the one row whose
    /// cost a plan could not state (an unknown number of objects in an unknown number of requests).
    @Test("a folder is never a candidate, at any depth")
    func foldersAreNeverCandidates() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.makeDir("L/docs")
        try tree.makeDir("R/docs")
        try tree.writeFile("L/docs/note.txt", contents: "aaaaa")
        try tree.writeFile("R/docs/note.txt", contents: "bbbbb")

        let candidates = DirectorySync.contentCandidates(in: try survey(tree))
        #expect(candidates.map(\.relativePath) == ["docs/note.txt"])
        #expect(!candidates.contains { $0.isDirectory })
    }

    // MARK: - Phase two

    /// The claim that makes the sheet's comparison picker free: a row's classification is a pure
    /// function of the two entries the walk captured, so re-deriving it reads no directory and
    /// answers exactly what walking again would have.
    @Test("re-deriving a comparison matches walking for it")
    func recompareMatchesAFreshWalk() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/same.txt", contents: "hello")
        try tree.writeFile("R/same.txt", contents: "hello")
        try tree.writeFile("L/newer.txt", contents: "aaaaa")
        try tree.writeFile("R/newer.txt", contents: "bbbbb")
        try tree.setModificationDate("L/same.txt", to: base)
        try tree.setModificationDate("R/same.txt", to: base)
        try tree.setModificationDate("L/newer.txt", to: base.addingTimeInterval(3600))
        try tree.setModificationDate("R/newer.txt", to: base)

        for comparison in [SyncComparison.size, .sizeAndDate] {
            let walked = try DirectorySync.compare(
                left: tree.vfsPath("L"),
                right: tree.vfsPath("R"),
                leftBackend: backend,
                rightBackend: backend,
                comparison: comparison
            )
            let derived = try DirectorySync.recompare(
                try survey(tree),
                between: .local,
                and: .local,
                comparison: comparison
            )
            #expect(derived == walked, "re-deriving \(comparison) disagreed with walking for it")
        }
    }

    /// The pairs the comparator is asked about are exactly the ones the gesture was told to fetch.
    /// Two spellings of that would fail in the quiet direction — a pair nobody predicted throws
    /// mid-scan, over a file sitting in front of the user.
    @Test("a content pass reads exactly the candidates and no other pair")
    func contentReadsExactlyTheCandidates() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/pair.txt", contents: "aaaaa")
        try tree.writeFile("R/pair.txt", contents: "bbbbb")
        try tree.writeFile("L/twin.txt", contents: "same")
        try tree.writeFile("R/twin.txt", contents: "same")
        try tree.writeFile("L/sizes-differ.txt", contents: "a longer body")
        try tree.writeFile("R/sizes-differ.txt", contents: "short")

        let surveyed = try survey(tree)
        var asked: [String] = []
        let rows = try DirectorySync.recompare(
            surveyed,
            between: .local,
            and: .local,
            comparison: .content,
            contentsEqual: { left, right in
                asked.append(left.lastComponent)
                return try ByteComparator.localFilesEqual(left, right)
            }
        )
        #expect(
            asked.sorted() == DirectorySync.contentCandidates(in: surveyed)
                .map(\.name).sorted()
        )
        #expect(asked.sorted() == ["pair.txt", "twin.txt"])
        // And the answer the reads bought: the same-size pair is a real difference, the identical
        // one is dropped, and the pair no byte was read for is still a difference.
        #expect(rows.map(\.relativePath) == ["pair.txt", "sizes-differ.txt"])
    }

    /// Reading bytes settles *whether* two files are equal and says nothing about which came later,
    /// so a content scan still ranks by the clock — and over a pair whose listings have no usable
    /// stamp it must not. With the guard removed this reports `.leftNewer`, which a bidirectional
    /// sync acts on: the left file copied over the right on the strength of a minute-resolution
    /// stamp read off `ls -la`.
    @Test("a content difference over a clockless pair is never ranked")
    func aContentDifferenceOverAClocklessPairIsNeverRanked() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/f.txt", contents: "aaaaa")
        try tree.writeFile("R/f.txt", contents: "bbbbb")
        try tree.setModificationDate("L/f.txt", to: base.addingTimeInterval(3600))
        try tree.setModificationDate("R/f.txt", to: base)
        let surveyed = try survey(tree)

        let clockless = try DirectorySync.recompare(
            surveyed,
            between: .local,
            and: sftp,
            comparison: .content
        )
        #expect(clockless.map(\.status) == [.differ])
        // The narrowness control: the identical fixture *is* ranked when both listings keep a clock
        // worth reading, so "never rank" has not become "never rank anything".
        let local = try DirectorySync.recompare(
            surveyed,
            between: .local,
            and: .local,
            comparison: .content
        )
        #expect(local.map(\.status) == [.leftNewer])
    }

    /// The half of `.content` that is not about bytes at all: a symlink has no contents to read, so
    /// the classification falls back to metadata — and over a clockless pair that fallback has to be
    /// **size alone**, or every link in the tree reports a difference on every scan because one side
    /// lists minutes where the other lists seconds.
    @Test("what a content scan cannot read falls back to size alone over a clockless pair")
    func theMetadataFallbackDropsTheClockToo() throws {
        let left = Self.entry("link", kind: .symlink, byteSize: 10, date: base)
        let right = Self.entry(
            "link",
            kind: .symlink,
            byteSize: 10,
            date: base.addingTimeInterval(41_617)
        )
        let row = SyncEntry(
            relativePath: "link",
            name: "link",
            left: left,
            right: right,
            status: .identical
        )
        let refuse: (VFSPath, VFSPath) throws -> Bool = { _, _ in
            Issue.record("a symlink pair has no contents and must never reach the comparator")
            return false
        }

        let clockless = try DirectorySync.recompare(
            [row],
            between: .local,
            and: sftp,
            comparison: .content,
            contentsEqual: refuse
        )
        #expect(clockless.isEmpty, "same size, and no clock either side can be believed")
        // The narrowness control: two local sides still read the date, so the fallback has not
        // quietly become "size alone, everywhere".
        let local = try DirectorySync.recompare(
            [row],
            between: .local,
            and: .local,
            comparison: .content,
            contentsEqual: refuse
        )
        #expect(local.map(\.status) == [.rightNewer])
    }

    /// A row that exists on one side, or is a file against a directory, is what it is whatever the
    /// comparison — so it passes through untouched rather than being re-derived from two entries it
    /// does not have.
    @Test("structural rows survive a re-derivation unchanged")
    func structuralRowsPassThrough() throws {
        let file = Self.entry("a", kind: .file, byteSize: 5, date: base)
        let folder = Self.entry("a", kind: .directory, byteSize: 96, date: base)
        let rows = [
            SyncEntry(relativePath: "a", name: "a", left: file, right: nil, status: .leftOnly),
            SyncEntry(relativePath: "b", name: "b", left: nil, right: file, status: .rightOnly),
            SyncEntry(relativePath: "c", name: "c", left: folder, right: file, status: .typeMismatch)
        ]
        let derived = try DirectorySync.recompare(
            rows,
            between: .local,
            and: .local,
            comparison: .content,
            contentsEqual: { _, _ in
                Issue.record("no structural row has two files to compare")
                return false
            }
        )
        #expect(derived == rows)
    }

    private static func entry(
        _ name: String,
        kind: FileEntry.Kind,
        byteSize: Int64,
        date: Date
    ) -> FileEntry {
        FileEntry(
            path: .local("/tmp/dirnex-content-fixture/\(name)"),
            name: name,
            kind: kind,
            byteSize: byteSize,
            modificationDate: date,
            creationDate: date,
            isHidden: false,
            permissions: 0o644,
            inode: 1
        )
    }
}
