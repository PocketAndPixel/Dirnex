import Foundation
import Testing

@testable import DirnexCore

/// What a pass of keeping takes and what it leaves (PLAN.md §M37 Slice 7).
@Suite("SyncRecordStore.keep")
struct SyncRecordKeepTests {
    private func report(kept: Int = 0, notEqual: Int = 0, notKeepable: Int = 0, overBudget: Int = 0) -> SyncKeepReport {
        var report = SyncKeepReport()
        report.kept = kept
        report.notEqual = notEqual
        report.notKeepable = notKeepable
        report.overBudget = overBudget
        return report
    }

    @Test("a text file both sides hold is kept under its relative path, with its bytes")
    func keepsEqual() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.tree.makeDir("L/sub/deep")
        try fixture.tree.makeDir("R/sub/deep")
        try fixture.writeBoth("a.txt", "top\n")
        try fixture.writeBoth("sub/deep/b.txt", "under\n")

        #expect(try fixture.keep() == report(kept: 2))
        #expect(try fixture.kept("a.txt") == "top\n")
        #expect(try fixture.kept("sub/deep/b.txt") == "under\n")
        #expect(try fixture.record.versions["a.txt"]?.keptAt == Date(timeIntervalSince1970: 1000))
        try fixture.expectStoreMatchesRecord()
    }

    @Test("a later edit of the file leaves the kept version as it was")
    func versionIsItsOwnCopy() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "as synced")
        try fixture.keep()
        try fixture.writeLeft("a.txt", "edited")
        #expect(try fixture.kept("a.txt") == "as synced")
    }

    @Test("an empty file is a version too")
    func emptyFile() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "")
        #expect(try fixture.keep() == report(kept: 1))
        #expect(try fixture.kept("a.txt")?.isEmpty == true)
    }

    @Test("sides of different sizes are not kept, and nothing is left behind")
    func differentSizes() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeLeft("a.txt", "short")
        try fixture.writeRight("a.txt", "much longer")
        #expect(try fixture.keep() == report(notEqual: 1))
        #expect(fixture.storedFiles.isEmpty)
    }

    @Test("sides of one size and different bytes are not kept, whatever their dates say")
    func sameSizeDifferentBytes() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeLeft("a.txt", "aaaa")
        try fixture.writeRight("a.txt", "bbbb")
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try fixture.tree.setModificationDate("L/a.txt", to: date)
        try fixture.tree.setModificationDate("R/a.txt", to: date)
        #expect(try fixture.keep() == report(notEqual: 1))
        #expect(fixture.storedFiles.isEmpty)
    }

    @Test("a binary file is not kept")
    func binary() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.bin", "te\0xt")
        #expect(try fixture.keep() == report(notKeepable: 1))
        #expect(fixture.storedFiles.isEmpty)
    }

    @Test("64 MiB is kept, and a byte more is not")
    func sizeLimit() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        let limit = Int(ByteComparator.prescanByteLimit)
        try fixture.tree.writeFile("L/at.txt", bytes: limit)
        try fixture.tree.writeFile("R/at.txt", bytes: limit)
        try fixture.tree.writeFile("L/over.txt", bytes: limit + 1)
        try fixture.tree.writeFile("R/over.txt", bytes: limit + 1)
        #expect(try fixture.keep() == report(kept: 1, notKeepable: 1))
        #expect(try fixture.record.keptFile(for: "at.txt") != nil)
        #expect(try fixture.record.keptFile(for: "over.txt") == nil)
    }

    @Test("a file on one side, a symlink and a folder against a file are no concern of a merge")
    func notFilesOnBothSides() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeLeft("only.txt", "left")
        try fixture.writeBoth("real.txt", "text")
        try fixture.tree.symlink("L/link.txt", to: "real.txt")
        try fixture.tree.symlink("R/link.txt", to: "real.txt")
        try fixture.writeLeft("clash", "a file")
        try fixture.tree.makeDir("R/clash")

        #expect(try fixture.keep() == report(kept: 1))
        #expect(try Set(fixture.record.versions.keys) == ["real.txt"])
    }

    @Test("a file inside a vault that sits within the folders is not kept")
    func vaultInsideTheWalk() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.tree.makeDir("L/vault")
        try fixture.tree.makeDir("R/vault")
        try fixture.writeBoth("vault/secret.txt", "private")
        try fixture.writeBoth("plain.txt", "public")

        let result = try fixture.keep(vaultMountPoints: [fixture.tree.path("L/vault")])
        #expect(result == report(kept: 1, notKeepable: 1))
        #expect(try Set(fixture.record.versions.keys) == ["plain.txt"])
    }

    @Test("what a file's stat says about placeholders decides before anything is read")
    func placeholderRule() {
        // SF_DATALESS cannot be set on a test file (see ComparisonSubject), so the decision is
        // driven directly, and the real scan's own refusal is ByteComparator's.
        let file = VFSPath.local("/a")
        func subject(regular: Bool = true, dataless: Bool = false) -> ComparisonSubject {
            ComparisonSubject(path: file, isRegularFile: regular, byteSize: 4, isDataless: dataless)
        }
        #expect(SyncRecordStore.mayRead(subject(), subject()))
        #expect(!SyncRecordStore.mayRead(subject(dataless: true), subject()))
        #expect(!SyncRecordStore.mayRead(subject(), subject(dataless: true)))
        #expect(!SyncRecordStore.mayRead(subject(regular: false), subject()))
        #expect(!SyncRecordStore.mayRead(subject(), subject(regular: false)))
    }

    @Test("a locked file's version can still be removed")
    func lockedFile() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "locked")
        let path = fixture.left("a.txt").path
        #expect(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(path, 0) }

        #expect(try fixture.keep() == report(kept: 1))
        let kept = try #require(try fixture.record.keptFile(for: "a.txt"))
        let attributes = try FileManager.default.attributesOfItem(atPath: kept.path)
        #expect((attributes[.immutable] as? Bool) == false)

        fixture.store.forget(fixture.pair)
        #expect(!FileManager.default.fileExists(atPath: kept.path))
    }

    @Test("a version can be read back whatever mode its file had")
    func modeIsTheStores() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "read only")
        let path = fixture.left("a.txt").path
        #expect(chmod(path, 0o444) == 0)

        #expect(try fixture.keep() == report(kept: 1))
        let kept = try #require(try fixture.record.keptFile(for: "a.txt"))
        let attributes = try FileManager.default.attributesOfItem(atPath: kept.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("a file that cannot be read is not kept, and does not stop the rest")
    func unreadable() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "locked up")
        try fixture.writeBoth("b.txt", "readable")
        #expect(chmod(fixture.left("a.txt").path, 0) == 0)
        #expect(try fixture.keep() == report(kept: 1, notKeepable: 1))
        #expect(try fixture.record.keptFile(for: "b.txt") != nil)
    }
}

/// What a later pass does to the versions an earlier one kept.
@Suite("SyncRecordStore.keep, again")
struct SyncRecordKeepAgainTests {
    @Test(
        "a file the sides disagree on keeps the version they last agreed on",
        arguments: [false, true]
    )
    func disagreementKeepsOld(editLeft: Bool) throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "agreed")
        try fixture.keep()
        let before = try fixture.record.versions["a.txt"]
        if editLeft {
            try fixture.writeLeft("a.txt", "edited")
        } else {
            try fixture.writeRight("a.txt", "edited")
        }

        let report = try fixture.keep(date: Date(timeIntervalSince1970: 2000))
        #expect(report.kept == 0)
        #expect(report.notEqual == 1)
        // The date included: a version the sides no longer hold was not confirmed by this pass.
        #expect(try fixture.record.versions["a.txt"] == before)
        #expect(try fixture.kept("a.txt") == "agreed")
        try fixture.expectStoreMatchesRecord()
    }

    @Test("sides that agree on something new replace the version, and the old file goes")
    func agreementReplaces() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "first")
        try fixture.keep()
        try fixture.writeBoth("a.txt", "second")

        try fixture.keep(date: Date(timeIntervalSince1970: 2000))
        #expect(try fixture.kept("a.txt") == "second")
        #expect(fixture.storedFiles.count == 1)
        try fixture.expectStoreMatchesRecord()
    }

    @Test("a file nothing changed keeps its version's file and takes the new date")
    func unchangedIsConfirmed() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "steady")
        try fixture.keep()
        let first = try #require(try fixture.record.versions["a.txt"])

        try fixture.keep(date: Date(timeIntervalSince1970: 2000))
        let second = try #require(try fixture.record.versions["a.txt"])
        #expect(second.file == first.file)
        #expect(second.keptAt == Date(timeIntervalSince1970: 2000))
    }

    @Test("a file gone from both sides is forgotten, with its version")
    func vanishedFromBoth() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "doomed")
        try fixture.writeBoth("b.txt", "stays")
        try fixture.keep()
        try FileManager.default.removeItem(at: fixture.left("a.txt"))
        try FileManager.default.removeItem(at: fixture.right("a.txt"))

        try fixture.keep()
        #expect(try Set(fixture.record.versions.keys) == ["b.txt"])
        try fixture.expectStoreMatchesRecord()
    }

    @Test("a file gone from one side keeps its version")
    func vanishedFromOne() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "half")
        try fixture.keep()
        try FileManager.default.removeItem(at: fixture.right("a.txt"))
        try fixture.keep()
        #expect(try fixture.kept("a.txt") == "half")
    }

    @Test("a file under a folder on only one side keeps its version")
    func underOneSidedFolder() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.tree.makeDir("L/dir/inner")
        try fixture.tree.makeDir("R/dir/inner")
        try fixture.writeBoth("dir/inner/a.txt", "deep")
        try fixture.keep()
        try FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.tree.path("R/dir")))

        try fixture.keep()
        #expect(try fixture.kept("dir/inner/a.txt") == "deep")
    }

    @Test("a name that only starts like a one-sided folder is not covered by it")
    func prefixIsNotAFolder() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.tree.makeDir("L/dir")
        try fixture.writeBoth("dir-2.txt", "doomed")
        try fixture.keep()
        try FileManager.default.removeItem(at: fixture.left("dir-2.txt"))
        try FileManager.default.removeItem(at: fixture.right("dir-2.txt"))
        try fixture.keep()
        #expect(try fixture.record.versions.isEmpty)
    }

    @Test("a folder that cannot be listed changes nothing")
    func walkFails() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "safe")
        try fixture.keep()
        try FileManager.default.removeItem(at: URL(fileURLWithPath: fixture.tree.path("R")))

        #expect(throws: (any Error).self) { try fixture.keep() }
        #expect(try fixture.kept("a.txt") == "safe")
    }

    @Test("a version whose file is gone is written again")
    func damagedVersionIsReplaced() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "again")
        try fixture.keep()
        let kept = try #require(try fixture.record.keptFile(for: "a.txt"))
        try FileManager.default.removeItem(at: kept)

        try fixture.keep()
        #expect(try fixture.kept("a.txt") == "again")
    }

    @Test("a stop at any moment leaves only finished versions and no strays")
    func stopAnywhere() throws {
        var sawPartial = false
        var sawWhole = false
        for stopAt in 0..<40 {
            let fixture = try SyncRecordFixture()
            defer { fixture.cleanup() }
            for name in ["a.txt", "b.txt", "c.txt"] { try fixture.writeBoth(name, "body of \(name)") }
            var calls = 0
            let report = try? fixture.store.keep(for: fixture.pair, using: fixture.backend) {
                defer { calls += 1 }
                return calls >= stopAt
            }
            let versions = try fixture.record.versions
            for (path, _) in versions { #expect(try fixture.kept(path) == "body of \(path)") }
            try fixture.expectStoreMatchesRecord()
            if let report {
                #expect(report.kept == versions.count)
                // A stop is not something that went wrong with a file.
                #expect(report.notKeepable == 0)
            }
            if !versions.isEmpty, versions.count < 3 { sawPartial = true }
            if versions.count == 3 { sawWhole = true }
        }
        // Without these, a loop that never reached the middle of a pass would pass as well.
        #expect(sawPartial)
        #expect(sawWhole)
    }

    @Test("a stop between files is heard without a read to hear it")
    func stopBetweenFiles() throws {
        // Empty files, since comparing two of them reads nothing and so never asks about a stop.
        var counts = Set<Int>()
        for stopAt in 0..<10 {
            let fixture = try SyncRecordFixture()
            defer { fixture.cleanup() }
            for name in ["a.txt", "b.txt", "c.txt"] { try fixture.writeBoth(name, "") }
            var calls = 0
            _ = try? fixture.store.keep(for: fixture.pair, using: fixture.backend) {
                defer { calls += 1 }
                return calls >= stopAt
            }
            try counts.insert(fixture.record.versions.count)
        }
        #expect(counts == [0, 1, 2, 3])
    }

    @Test("a side that cannot be read once the clone is made counts as not kept, and leaves nothing")
    func otherSideUnreadable() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "one side only")
        #expect(chmod(fixture.right("a.txt").path, 0) == 0)

        let report = try fixture.keep()
        #expect(report.kept == 0)
        #expect(report.notKeepable == 1)
        #expect(fixture.storedFiles.isEmpty)
    }

    @Test("a record that cannot be written removes this pass's files and leaves the last ones")
    func writeFails() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        for name in ["a.txt", "b.txt"] { try fixture.writeBoth(name, "old") }
        try fixture.keep()
        let before = fixture.storedFiles.sorted()
        for name in ["a.txt", "b.txt"] { try fixture.writeBoth(name, "new!") }
        let file = fixture.store.directory(of: fixture.pair).appendingPathComponent("record.json")
        let saved = try Data(contentsOf: file)
        var broken = false

        #expect(throws: (any Error).self) {
            try fixture.store.keep(for: fixture.pair, using: fixture.backend) {
                // A folder in its place, once the pass has begun writing, so the last rename fails.
                if !broken, fixture.storedFiles.count > before.count {
                    broken = true
                    try? FileManager.default.removeItem(at: file)
                    try? FileManager.default.createDirectory(
                        at: file.appendingPathComponent("full"),
                        withIntermediateDirectories: true
                    )
                }
                return false
            }
        }
        #expect(broken)
        #expect(fixture.storedFiles.sorted() == before)

        try FileManager.default.removeItem(at: file)
        try saved.write(to: file)
        #expect(try fixture.kept("a.txt") == "old")
    }
}
