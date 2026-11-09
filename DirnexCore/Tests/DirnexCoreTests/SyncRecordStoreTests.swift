import Foundation
import Testing

@testable import DirnexCore

/// Which pairs can have a record, and what makes one exist (PLAN.md §M37 Slice 7).
@Suite("SyncRecordPair")
struct SyncRecordPairTests {
    private let sftp = VFSBackendID.sftp(SFTPLocation(host: "example.test", username: "oleg"))

    private func pair(_ left: String, _ right: String, vaults: [String] = []) -> SyncRecordPair? {
        SyncRecordPair(left: .local(left), right: .local(right), vaultMountPoints: vaults)
    }

    @Test("a side on a server has no record")
    func serverSide() {
        let server = VFSPath(backend: sftp, path: "/srv")
        #expect(SyncRecordPair(left: server, right: .local("/a"), vaultMountPoints: []) == nil)
        #expect(SyncRecordPair(left: .local("/a"), right: server, vaultMountPoints: []) == nil)
        #expect(SyncRecordPair(left: server, right: server, vaultMountPoints: []) == nil)
    }

    @Test("a folder has no record with itself, however it is spelled")
    func sameFolder() {
        #expect(pair("/a", "/a") == nil)
        #expect(pair("/tmp/a", "/private/tmp/a") == nil)
    }

    @Test("a side inside a vault has no record, and a neighbour of one does")
    func vault() {
        #expect(pair("/Volumes/Vault/a", "/b", vaults: ["/Volumes/Vault"]) == nil)
        #expect(pair("/b", "/Volumes/Vault", vaults: ["/Volumes/Vault"]) == nil)
        #expect(pair("/Volumes/VaultBackup/a", "/b", vaults: ["/Volumes/Vault"]) != nil)
    }

    @Test("swapping the panes finds the same record")
    func undirected() throws {
        let one = try #require(pair("/a", "/b"))
        let other = try #require(pair("/b", "/a"))
        #expect(one == other)
        #expect(one.key == other.key)
    }

    @Test("one folder under two spellings is one pair")
    func spellings() throws {
        let one = try #require(pair("/tmp/a", "/b"))
        let other = try #require(pair("/private/tmp/a", "/b"))
        #expect(one == other)
    }

    @Test("the folder's name does not change between launches")
    func keyIsStable() throws {
        let one = try #require(pair("/a", "/b"))
        #expect(one.key == "148c32fbefbb40c1555fcf69a5d463fe673d6c4a267a2f5caa1bd0a2cb32eccc")
    }

    @Test("two pairs whose paths run together stay two")
    func separator() throws {
        let one = try #require(pair("/a", "/b/c"))
        let other = try #require(pair("/a/b", "/c"))
        #expect(one.key != other.key)
    }
}

@Suite("SyncRecordStore")
struct SyncRecordStoreTests {
    @Test("the store is in a folder Spotlight skips, and Time Machine does too once it exists")
    func unindexed() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        #expect(fixture.store.root.lastPathComponent.hasSuffix(".noindex"))
        #expect(fixture.store.root.deletingLastPathComponent().path == fixture.tree.root.path)
        let values = try fixture.store.root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("a pair has no record until it is remembered")
    func rememberedOnAsking() throws {
        let fixture = try SyncRecordFixture(remembering: false)
        defer { fixture.cleanup() }
        #expect(fixture.store.record(for: fixture.pair) == nil)
        try fixture.store.remember(fixture.pair)
        let record = try fixture.record
        #expect(record.pair == fixture.pair)
        #expect(record.versions.isEmpty)
    }

    @Test("whether a pair is remembered can be asked without reading its record")
    func isRemembered() throws {
        let fixture = try SyncRecordFixture(remembering: false)
        defer { fixture.cleanup() }
        #expect(!fixture.store.isRemembered(fixture.pair))
        try fixture.store.remember(fixture.pair)
        #expect(fixture.store.isRemembered(fixture.pair))
        fixture.store.forget(fixture.pair)
        #expect(!fixture.store.isRemembered(fixture.pair))
    }

    @Test("a pair nobody asked to remember keeps nothing, and writes nothing")
    func nothingUnasked() throws {
        let fixture = try SyncRecordFixture(remembering: false)
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "same")
        #expect(try fixture.keep() == SyncKeepReport())
        #expect(!FileManager.default.fileExists(atPath: fixture.store.root.path))
    }

    @Test("remembering again keeps what the record has")
    func rememberTwice() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "same")
        try fixture.keep()
        try fixture.store.remember(fixture.pair)
        #expect(try fixture.kept("a.txt") == "same")
    }

    @Test("forgetting removes the record and its versions, and no one else's")
    func forget() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "same")
        try fixture.keep()
        let directory = fixture.store.directory(of: fixture.pair)
        let other = try #require(SyncRecordPair(
            left: fixture.tree.vfsPath("L"),
            right: fixture.tree.vfsPath("elsewhere"),
            vaultMountPoints: []
        ))
        try fixture.store.remember(other)

        fixture.store.forget(fixture.pair)
        #expect(fixture.store.record(for: fixture.pair) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(fixture.store.record(for: other) != nil)
        // The user's files were never in it.
        #expect(FileManager.default.fileExists(atPath: fixture.left("a.txt").path))
    }

    @Test("a record that cannot be read is no record")
    func damaged() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        let file = fixture.store.directory(of: fixture.pair).appendingPathComponent("record.json")
        try Data("not json".utf8).write(to: file)
        #expect(fixture.store.record(for: fixture.pair) == nil)
    }

    @Test("a record cannot name a file outside its folder")
    func manifestCannotEscape() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        let victim = try fixture.tree.writeFile("victim.txt", contents: "mine")
        let directory = fixture.store.directory(of: fixture.pair)
        let body = """
        {"pair":{"first":"\(fixture.pair.first)","second":"\(fixture.pair.second)"},
        "versions":{"a.txt":{"file":"../../victim.txt","byteSize":4,"keptAt":0}}}
        """
        try Data(body.utf8).write(to: directory.appendingPathComponent("record.json"))

        #expect(fixture.store.record(for: fixture.pair) == nil)
        fixture.store.purge()
        #expect(FileManager.default.fileExists(atPath: victim))
    }

    @Test("a record belonging to another pair is no record of this one")
    func anotherPairsRecord() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        let other = try #require(SyncRecordPair(
            left: fixture.tree.vfsPath("A"),
            right: fixture.tree.vfsPath("B"),
            vaultMountPoints: []
        ))
        try fixture.store.write(
            .init(pair: other, versions: [:]),
            to: fixture.store.directory(of: fixture.pair)
        )
        #expect(fixture.store.record(for: fixture.pair) == nil)
    }

    @Test("a launch clears what no record names and leaves what one does")
    func purge() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        try fixture.writeBoth("a.txt", "same")
        try fixture.keep()
        let directory = fixture.store.directory(of: fixture.pair)
        try Data("left by a crash".utf8).write(
            to: directory.appendingPathComponent(UUID().uuidString)
        )
        let stray = fixture.store.root.appendingPathComponent("no-record-here", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        fixture.store.purge()
        #expect(!FileManager.default.fileExists(atPath: stray.path))
        #expect(fixture.storedFiles.count == 1)
        #expect(try fixture.kept("a.txt") == "same")
    }

    @Test("a record filed under the wrong folder is cleared at launch")
    func purgeMisfiled() throws {
        let fixture = try SyncRecordFixture()
        defer { fixture.cleanup() }
        let misfiled = fixture.store.root.appendingPathComponent("wrong", isDirectory: true)
        try FileManager.default.createDirectory(at: misfiled, withIntermediateDirectories: true)
        try fixture.store.write(.init(pair: fixture.pair, versions: [:]), to: misfiled)
        fixture.store.purge()
        #expect(!FileManager.default.fileExists(atPath: misfiled.path))
    }
}
