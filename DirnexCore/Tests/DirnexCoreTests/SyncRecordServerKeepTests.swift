import Foundation
import Testing

@testable import DirnexCore

/// Keeping on a pair with a server side: only what the sync copied, with the server's stamp beside
/// it, and no server byte read (PLAN.md §M38 Slice 8).
@Suite("SyncRecordStore, with a server side")
struct SyncRecordServerKeepTests {
    @Test("an upload is kept, with the server's row beside it, and nothing is downloaded")
    func upload() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "one\n")

        let report = try fixture.sync()

        #expect(report == SyncKeepReport(kept: 1))
        #expect(try fixture.kept("a.txt") == "one\n")
        let version = try #require(try fixture.record.versions["a.txt"])
        #expect(version.serverRevision == RemoteFileRevision(try fixture.serverEntry("a.txt")))
        #expect(fixture.server.byteReads == 0)
        try fixture.expectStoreMatchesRecord()
    }

    @Test("a download is kept the same way")
    func download() throws {
        let fixture = try ServerSyncFixture(serverOnLeft: true, tags: true)
        defer { fixture.cleanup() }
        fixture.writeServer("a.txt", "theirs\n")

        #expect(try fixture.sync() == SyncKeepReport(kept: 1))
        #expect(try fixture.localText("a.txt") == "theirs\n")
        #expect(try fixture.kept("a.txt") == "theirs\n")
        let version = try #require(try fixture.record.versions["a.txt"])
        #expect(version.serverRevision?.entityTag == "\"t1\"")
        #expect(fixture.server.byteReads == 0)
    }

    @Test("a folder copied whole keeps the text files in it, each with its own stamp")
    func wholeFolder() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("docs/a.txt", "a\n")
        try fixture.writeLocal("docs/deep/b.md", "# b\n")
        try Data([0, 1, 2, 0]).write(to: fixture.local("docs/pic.bin"))

        #expect(try fixture.sync() == SyncKeepReport(kept: 2, notKeepable: 1))
        #expect(try fixture.kept("docs/a.txt") == "a\n")
        #expect(try fixture.kept("docs/deep/b.md") == "# b\n")
        #expect(try fixture.kept("docs/pic.bin") == nil)
        #expect(try fixture.record.versions["docs/deep/b.md"]?.serverRevision
            == RemoteFileRevision(try fixture.serverEntry("docs/deep/b.md")))
    }

    @Test("a file both sides already held is not kept, since nothing was copied for it")
    func notCopied() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("same.txt", "both\n")
        fixture.writeServer("same.txt", "both\n")
        try fixture.writeLocal("new.txt", "new\n")

        #expect(try fixture.sync() == SyncKeepReport(kept: 1))
        #expect(try fixture.record.versions.keys.sorted() == ["new.txt"])
    }

    @Test("a sync that copied nothing walks nothing and keeps nothing")
    func nothingCopied() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("same.txt", "both\n")
        fixture.writeServer("same.txt", "both\n")
        let decisions = try fixture.decisions(fixture.compare())
        let listings = fixture.server.listings

        #expect(try fixture.keep(after: decisions) == SyncKeepReport())
        #expect(fixture.server.listings == listings)
        #expect(try fixture.record.versions.isEmpty)
    }

    @Test("a copy that did not land keeps nothing, even where the sizes agree")
    func failedCopy() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        // One size on both sides, so only the server's unmoved stamp can tell. A `.size` comparison
        // calls the pair identical; a content comparison, or a hand-picked action, copies it.
        try fixture.writeLocal("a.txt", "mine\n")
        fixture.writeServer("a.txt", "old!\n")
        try fixture.writeLocal("b.txt", "longer than before\n")
        fixture.writeServer("b.txt", "short\n")
        let decisions = try fixture.decisions(
            fixture.compare(includingIdentical: true),
            direction: .leftToRight,
            overrides: ["a.txt": .copyToRight]
        )

        let report = try fixture.keep(after: decisions)

        #expect(report == SyncKeepReport(notEqual: 2))
        #expect(try fixture.record.versions.isEmpty)
    }

    @Test("a download that did not land keeps nothing, even where the sizes agree")
    func failedDownload() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "mine\n")
        fixture.writeServer("a.txt", "old!\n")
        let decisions = try fixture.decisions(
            fixture.compare(includingIdentical: true),
            overrides: ["a.txt": .copyToLeft]
        )

        #expect(try fixture.keep(after: decisions) == SyncKeepReport(notEqual: 1))
        #expect(try fixture.record.versions.isEmpty)
    }

    @Test("an upload whose local file was written after the comparison is not kept")
    func localWrittenSince() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "mine\n")
        let decisions = try fixture.decisions(fixture.compare())
        try fixture.copy(decisions)
        // Another app saves the same length after the upload took the listed bytes.
        try fixture.writeLocal("a.txt", "MINE\n")
        try fixture.tree.setModificationDate(
            "L/a.txt",
            to: Date(timeIntervalSince1970: 2_000_000_000)
        )

        #expect(try fixture.keep(after: decisions) == SyncKeepReport(notEqual: 1))
        #expect(try fixture.record.versions.isEmpty)
    }

    @Test("a download whose server file was written after the comparison is not kept")
    func serverWrittenSince() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        fixture.writeServer("a.txt", "theirs\n")
        let decisions = try fixture.decisions(fixture.compare())
        try fixture.copy(decisions)
        fixture.writeServer("a.txt", "THEIRS\n")

        #expect(try fixture.keep(after: decisions) == SyncKeepReport(notEqual: 1))
        #expect(try fixture.record.versions.isEmpty)
    }

    @Test("a later sync replaces a version, and the old one goes")
    func replaces() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "one\n")
        try fixture.sync()
        let first = try #require(try fixture.record.versions["a.txt"])
        fixture.writeServer("a.txt", "two, from the server\n")

        #expect(try fixture.sync(direction: .rightToLeft) == SyncKeepReport(kept: 1))
        let second = try #require(try fixture.record.versions["a.txt"])
        #expect(second.file != first.file)
        #expect(try fixture.kept("a.txt") == "two, from the server\n")
        try fixture.expectStoreMatchesRecord()
    }

    @Test("a file gone from both sides is forgotten by the next sync that copies something")
    func forgets() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("gone.txt", "soon\n")
        try fixture.sync()
        try FileManager.default.removeItem(at: fixture.local("gone.txt"))
        fixture.server.remove(fixture.serverPath("gone.txt"))
        try fixture.writeLocal("b.txt", "b\n")

        try fixture.sync()

        #expect(try fixture.record.versions.keys.sorted() == ["b.txt"])
        try fixture.expectStoreMatchesRecord()
    }

    @Test("a pair the user has not asked to remember keeps nothing, and is not walked")
    func notRemembered() throws {
        let fixture = try ServerSyncFixture(remembering: false)
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "one\n")
        let decisions = try fixture.decisions(fixture.compare())
        try fixture.copy(decisions)
        let listings = fixture.server.listings

        #expect(try fixture.keep(after: decisions) == SyncKeepReport())
        #expect(fixture.server.listings == listings)
        #expect(fixture.store.record(for: fixture.pair) == nil)
    }

    @Test("a walk never keeps a server pair's files")
    func walkRefuses() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "one\n")
        fixture.writeServer("a.txt", "one\n")
        let listings = fixture.server.listings

        #expect(try fixture.store.keep(for: fixture.pair, using: fixture.server) == SyncKeepReport())
        #expect(fixture.server.listings == listings)
        #expect(try fixture.record.versions.isEmpty)
    }

    @Test("a local pair given a sync's decisions is walked, as before")
    func localPair() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "both\n")

        let report = try fixture.store.keep(after: [], for: fixture.pair, using: fixture.backend)

        #expect(report == SyncKeepReport(kept: 1))
        #expect(try fixture.kept("a.txt") == "both\n")
    }

    @Test("the stamp is kept by the route the comparison reads it by")
    func sameRoute() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        // The subtree shortcut prints its dates its own way, as SFTP's exec channel does.
        fixture.server.subtreeDateShift = 30
        try fixture.writeLocal("a.txt", "one\n")
        try fixture.writeLocal("d/b.txt", "two\n")
        let decisions = try fixture.decisions(fixture.compare())
        try fixture.copy(decisions)
        let listings = fixture.server.listings

        #expect(try fixture.keep(after: decisions) == SyncKeepReport(kept: 2))
        #expect(fixture.server.listings == listings + 1)
        #expect(try fixture.change("a.txt") == .unchanged)
        #expect(try fixture.change("d/b.txt") == .unchanged)
    }

    @Test("what does not fit the budget is counted")
    func budget() throws {
        let fixture = try ServerSyncFixture(budget: SyncRecordBudget(bytes: 6))
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "four\n")
        try fixture.writeLocal("b.txt", "longer\n")

        #expect(try fixture.sync() == SyncKeepReport(kept: 1, overBudget: 1))
        #expect(try fixture.record.versions.keys.sorted() == ["a.txt"])
    }

    @Test("a merge saved into both sides becomes the version, with the server's new row beside it")
    func mergeSaved() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "one\n")
        try fixture.sync()
        try fixture.writeLocal("a.txt", "merged\n")
        fixture.writeServer("a.txt", "merged\n")

        let report = try fixture.store.keep(
            relativePath: "a.txt",
            local: fixture.local("a.txt"),
            server: fixture.serverEntry("a.txt"),
            for: fixture.pair
        )

        #expect(report == SyncKeepReport(kept: 1))
        #expect(try fixture.kept("a.txt") == "merged\n")
        #expect(
            try fixture.record.changes(of: fixture.compare(includingIdentical: true))["a.txt"] == .unchanged
        )
        try fixture.expectStoreMatchesRecord()
    }

    @Test("a merge whose upload did not land keeps the version it had")
    func mergeNotLanded() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "one\n")
        try fixture.sync()
        let before = try fixture.record
        try fixture.writeLocal("a.txt", "merged\n")

        let report = try fixture.store.keep(
            relativePath: "a.txt",
            local: fixture.local("a.txt"),
            server: fixture.serverEntry("a.txt"),
            for: fixture.pair
        )

        #expect(report == SyncKeepReport(notEqual: 1))
        #expect(try fixture.record == before)
    }
}
