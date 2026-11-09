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
