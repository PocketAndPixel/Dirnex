import Foundation
import Testing

@testable import DirnexCore

/// The budget, carried out on real records (PLAN.md §M37 Slice 7).
@Suite("SyncRecordStore.keep, budget")
struct SyncRecordKeepBudgetTests {
    private func secondPair(_ fixture: SyncRecordFixture) throws -> SyncRecordPair {
        try fixture.tree.makeDir("L2")
        try fixture.tree.makeDir("R2")
        let pair = try #require(SyncRecordPair(
            left: fixture.tree.vfsPath("L2"),
            right: fixture.tree.vfsPath("R2"),
            vaultMountPoints: []
        ))
        try fixture.store.remember(pair)
        return pair
    }

    @Test("files that do not fit are counted, and the rest are kept")
    func overBudget() throws {
        let fixture = try SyncRecordFixture(budget: SyncRecordBudget(bytes: 10))
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "aaaaaa")
        try fixture.writeBoth("b.txt", "bbbbbb")
        try fixture.writeBoth("c.txt", "cccc")
        let report = try fixture.keep()
        #expect(report.kept == 2)
        #expect(report.overBudget == 1)
        #expect(try Set(fixture.record.versions.keys) == ["a.txt", "c.txt"])
    }

    @Test("another pair's oldest version goes first, and that pair stays remembered")
    func acrossRecords() throws {
        let fixture = try SyncRecordFixture(budget: SyncRecordBudget(bytes: 10))
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "aaaaaa")
        try fixture.keep(date: Date(timeIntervalSince1970: 1000))
        let older = try #require(try fixture.record.keptFile(for: "a.txt"))

        let pair = try secondPair(fixture)
        try fixture.tree.writeFile("L2/b.txt", contents: "bbbbbb")
        try fixture.tree.writeFile("R2/b.txt", contents: "bbbbbb")
        let report = try fixture.store.keep(
            for: pair,
            using: fixture.backend,
            date: Date(timeIntervalSince1970: 2000)
        )

        #expect(report.kept == 1)
        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(try fixture.record.versions.isEmpty)
        #expect(fixture.store.record(for: pair)?.versions.count == 1)
    }

    @Test("a version about to be replaced does not push anything else out")
    func replacedVersionIsFree() throws {
        let fixture = try SyncRecordFixture(budget: SyncRecordBudget(bytes: 10))
        defer { fixture.cleanup() }
        let pair = try secondPair(fixture)
        try fixture.tree.writeFile("L2/b.txt", contents: "bb")
        try fixture.tree.writeFile("R2/b.txt", contents: "bb")
        // Older than the version being replaced, so a wrong count would push this one out first.
        _ = try fixture.store.keep(
            for: pair,
            using: fixture.backend,
            date: Date(timeIntervalSince1970: 500)
        )

        try fixture.writeBoth("a.txt", "aaaaaa")
        try fixture.keep()
        try fixture.writeBoth("a.txt", "AAAAAAAA")
        try fixture.keep()

        #expect(try fixture.kept("a.txt") == "AAAAAAAA")
        #expect(fixture.store.record(for: pair)?.versions.count == 1)
        try fixture.expectStoreMatchesRecord()
    }

    @Test("a version confirmed by a newer sync outlasts one that was not")
    func confirmedIsYounger() throws {
        let fixture = try SyncRecordFixture(budget: SyncRecordBudget(bytes: 10))
        defer { fixture.cleanup() }
        try fixture.writeBoth("old.txt", "oooo")
        try fixture.writeBoth("steady.txt", "ssss")
        try fixture.keep(date: Date(timeIntervalSince1970: 1000))
        // Only old.txt falls out of agreement, so only steady.txt is confirmed by the next pass.
        try fixture.writeLeft("old.txt", "differs")
        try fixture.keep(date: Date(timeIntervalSince1970: 2000))
        try fixture.writeBoth("new.txt", "nnnn")

        try fixture.keep(date: Date(timeIntervalSince1970: 3000))
        #expect(try Set(fixture.record.versions.keys) == ["new.txt", "steady.txt"])
        try fixture.expectStoreMatchesRecord()
    }
}

/// Keeping the one file a merge just wrote to both sides (PLAN.md §M37 Slice 8).
@Suite("SyncRecordStore.keep, one file")
struct SyncRecordKeepOneTests {
    private func keepOne(_ fixture: SyncRecordFixture, _ path: String = "a.txt") throws -> SyncKeepReport {
        try fixture.store.keep(
            relativePath: path,
            left: fixture.left(path),
            right: fixture.right(path),
            for: fixture.pair
        )
    }

    @Test("what both sides now hold becomes the version, and the old one goes")
    func replaces() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "old")
        try fixture.keep()
        try fixture.writeBoth("a.txt", "merged")

        #expect(try keepOne(fixture).kept == 1)
        #expect(try fixture.kept("a.txt") == "merged")
        try fixture.expectStoreMatchesRecord()
    }

    @Test("other files are left as they were, even ones gone from both sides")
    func looksAtOneFile() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "old")
        try fixture.writeBoth("gone.txt", "kept")
        try fixture.keep()
        try FileManager.default.removeItem(at: fixture.left("gone.txt"))
        try FileManager.default.removeItem(at: fixture.right("gone.txt"))
        try fixture.writeBoth("a.txt", "merged")

        _ = try keepOne(fixture)
        #expect(try Set(fixture.record.versions.keys) == ["a.txt", "gone.txt"])
    }

    @Test("sides that do not agree keep the old version")
    func notEqual() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "old")
        try fixture.keep()
        try fixture.writeLeft("a.txt", "mine")
        try fixture.writeRight("a.txt", "yours")

        #expect(try keepOne(fixture).notEqual == 1)
        #expect(try fixture.kept("a.txt") == "old")
    }

    @Test("a pair nobody asked to remember keeps nothing")
    func notRemembered() throws {
        let fixture = try SyncRecordFixture(remembering: false)
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "merged")
        #expect(try keepOne(fixture) == SyncKeepReport())
        #expect(!FileManager.default.fileExists(atPath: fixture.store.root.path))
    }

    @Test("a file that is not there, or not text, or in a vault is not kept")
    func notKeepable() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        #expect(try keepOne(fixture, "missing.txt").notKeepable == 1)
        try fixture.writeBoth("a.bin", "te\0xt")
        #expect(try keepOne(fixture, "a.bin").notKeepable == 1)

        try fixture.writeBoth("a.txt", "private")
        let report = try fixture.store.keep(
            relativePath: "a.txt",
            left: fixture.left("a.txt"),
            right: fixture.right("a.txt"),
            for: fixture.pair,
            vaultMountPoints: [fixture.tree.path("R")]
        )
        #expect(report.notKeepable == 1)
        #expect(try fixture.record.versions.isEmpty)
    }

    @Test("a file past the budget is counted")
    func overBudget() throws {
        let fixture = try SyncRecordFixture(budget: SyncRecordBudget(bytes: 3))
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "too long")
        #expect(try keepOne(fixture).overBudget == 1)
        #expect(try fixture.record.versions.isEmpty)
    }
}
