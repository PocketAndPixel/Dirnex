import Foundation
import Testing

@testable import DirnexCore

/// What a directory sync may honestly offer over a given pair of sides, and what the clockless
/// comparison does once chosen (PLAN.md §M25 Slice 5c).
@Suite("SyncComparison — what a pair of sides may be offered")
struct SyncComparisonAvailabilityTests {
    private let sftp = VFSBackendID.sftp(SFTPLocation(host: "example.test", username: "oleg"))
    private let ftp = VFSBackendID.ftp(FTPLocation(host: "example.test", username: "oleg"))
    private let s3 = VFSBackendID.s3(
        S3Location(
            host: "s3.eu-north-1.amazonaws.com",
            bucket: "b",
            region: "eu-north-1",
            accessKeyID: "AKIA"
        )
    )

    @Test("two local sides get every comparison")
    func localPairGetsEverything() {
        #expect(
            SyncComparison.available(between: .local, and: .local) == [.size, .sizeAndDate, .content]
        )
    }

    @Test("one remote side withdraws the date comparison, whichever side it is")
    func oneRemoteSideWithdrawsDates() {
        #expect(SyncComparison.available(between: .local, and: sftp) == [.size])
        #expect(SyncComparison.available(between: sftp, and: .local) == [.size])
        #expect(SyncComparison.available(between: .local, and: ftp) == [.size])
        #expect(SyncComparison.available(between: .local, and: s3) == [.size])
    }

    /// The case that is easy to get wrong by reading "coarse" as "coarse in a different way": two
    /// `sftp` sides share one dialect and are *still* not comparable, because two files thirty
    /// seconds apart both list as the same minute — so a mirror would call them identical and skip
    /// the one that changed. Measured against a real `sshd` (docs/NOTES.md ▸ sftp / ssh).
    @Test("two sides of the same coarse dialect are still not comparable by date")
    func twoCoarseSidesAreStillNotComparable() {
        #expect(SyncComparison.available(between: sftp, and: sftp) == [.size])
        #expect(SyncComparison.available(between: ftp, and: ftp) == [.size])
    }

    @Test("contents is offered only when both sides are on this disk")
    func contentsNeedsTwoLocalSides() {
        #expect(SyncComparison.available(between: .local, and: .local).contains(.content))
        for remote in [sftp, ftp, s3, VFSBackendID.archive(forArchiveAt: "/tmp/a.zip")] {
            #expect(!SyncComparison.available(between: .local, and: remote).contains(.content))
            #expect(!SyncComparison.available(between: remote, and: .local).contains(.content))
        }
    }

    @Test("the opening comparison is the strongest cheap one available")
    func defaultComparison() {
        #expect(SyncComparison.default(between: .local, and: .local) == .sizeAndDate)
        #expect(SyncComparison.default(between: .local, and: sftp) == .size)
        #expect(SyncComparison.default(between: s3, and: ftp) == .size)
    }

    @Test("only the local disk lists a modification time worth comparing")
    func onlyLocalHasComparableTimes() {
        #expect(VFSBackendID.local.hasComparableModificationTimes)
        #expect(!sftp.hasComparableModificationTimes)
        #expect(!ftp.hasComparableModificationTimes)
        #expect(!s3.hasComparableModificationTimes)
        let account = S3Account(host: "h", region: "r", accessKeyID: "AKIA")
        #expect(!VFSBackendID.s3Account(account).hasComparableModificationTimes)
        #expect(!VFSBackendID.archive(forArchiveAt: "/tmp/a.zip").hasComparableModificationTimes)
    }

    @Test("only the size comparison ignores the clock")
    func onlySizeIgnoresTheClock() {
        #expect(!SyncComparison.size.usesModificationDates)
        #expect(SyncComparison.sizeAndDate.usesModificationDates)
        #expect(SyncComparison.content.usesModificationDates)
    }
}

/// The clockless comparison in the engine: what it calls equal, and — the half that matters — what
/// it refuses to rank.
@Suite("DirectorySync — comparing by size alone")
struct DirectorySyncBySizeTests {
    private let backend = LocalBackend()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func twoRoots() throws -> TempTree {
        let tree = try TempTree()
        try tree.makeDir("L")
        try tree.makeDir("R")
        return tree
    }

    private func compare(_ tree: TempTree, _ comparison: SyncComparison) throws -> [SyncEntry] {
        try DirectorySync.compare(
            left: tree.vfsPath("L"),
            right: tree.vfsPath("R"),
            leftBackend: backend,
            rightBackend: backend,
            comparison: comparison
        )
    }

    /// The whole point of the mode: a file copied to a server and listed back reads minutes rather
    /// than seconds, so the dates disagree while the file is untouched. Comparing by size says so.
    @Test("same size and wildly different dates is identical by size and a difference by date")
    func datesAreIgnored() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/f.txt", contents: "hello")
        try tree.writeFile("R/f.txt", contents: "hello")
        try tree.setModificationDate("L/f.txt", to: base)
        try tree.setModificationDate("R/f.txt", to: base.addingTimeInterval(41_617))

        #expect(try compare(tree, .size).isEmpty)
        let byDate = try compare(tree, .sizeAndDate)
        #expect(byDate.count == 1)
        #expect(byDate[0].status == .rightNewer)
    }

    /// A clockless comparison must not name a winner, and this is the assertion the guard exists
    /// for: with it removed the same fixture reports `.leftNewer`, which a bidirectional sync would
    /// act on — copying the left file over the right on the strength of a stamp nothing can read.
    @Test("a difference found by size alone is never ranked newer or older")
    func aSizeDifferenceIsNeverRanked() throws {
        let tree = try twoRoots()
        defer { tree.cleanup() }
        try tree.writeFile("L/f.txt", contents: "a longer body")
        try tree.writeFile("R/f.txt", contents: "short")
        try tree.setModificationDate("L/f.txt", to: base.addingTimeInterval(3600))
        try tree.setModificationDate("R/f.txt", to: base)

        let bySize = try compare(tree, .size)
        #expect(bySize.count == 1)
        #expect(bySize[0].status == .differ)
        // The narrowness control: the same fixture *is* ranked when the clock may be believed, so
        // "never rank" has not quietly become "never rank anything".
        #expect(try compare(tree, .sizeAndDate).first?.status == .leftNewer)
    }

    /// `.differ` is what a bidirectional run refuses to guess at and a mirror still acts on, so the
    /// clockless mode is usable in one direction and honest in the other.
    @Test("an unranked difference is a conflict both ways and a copy under a mirror")
    func unrankedDifferenceDefaults() {
        #expect(DirectorySync.defaultAction(for: .differ, direction: .bidirectional) == .conflict)
        #expect(DirectorySync.defaultAction(for: .differ, direction: .leftToRight) == .copyToRight)
        #expect(DirectorySync.defaultAction(for: .differ, direction: .rightToLeft) == .copyToLeft)
    }
}
