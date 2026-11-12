import CryptoKit
import Foundation
import Testing

@testable import DirnexCore

/// Which pairs with a server side can have a record, and how one is written down (PLAN.md §M38
/// Slice 8).
@Suite("SyncRecordPair, with a server side")
struct SyncRecordServerPairTests {
    private let local = VFSPath.local("/Users/probe/Notes")
    private let server = VFSPath(backend: StampedServer.serverID, path: "/home/probe/notes")

    @Test("a local folder and a server folder make a pair, either way round")
    func either() throws {
        let one = try #require(SyncRecordPair(
            left: local,
            right: server,
            vaultMountPoints: [],
            allowingServerSide: true
        ))
        let other = try #require(SyncRecordPair(
            left: server,
            right: local,
            vaultMountPoints: [],
            allowingServerSide: true
        ))
        #expect(one == other)
        #expect(one.key == other.key)
        #expect(one.first == "/Users/probe/Notes")
        #expect(one.serverFolder == server)
    }

    @Test("a server side is refused unless the caller allows one, as the app's call does today")
    func notAllowed() {
        #expect(SyncRecordPair(left: local, right: server, vaultMountPoints: []) == nil)
        #expect(SyncRecordPair(left: server, right: local, vaultMountPoints: []) == nil)
    }

    @Test("two servers, and a side no file can be uploaded to, have no record")
    func refused() {
        let other = VFSPath(
            backend: .sftp(SFTPLocation(host: "other.test", username: "probe")),
            path: "/srv"
        )
        #expect(SyncRecordPair(
            left: server,
            right: other,
            vaultMountPoints: [],
            allowingServerSide: true
        ) == nil)
        for backend: VFSBackendID in [
            .photos,
            .search,
            .trash,
            .icloud,
            .archive(forArchiveAt: "/tmp/a.zip")
        ] {
            #expect(SyncRecordPair(
                left: local,
                right: VFSPath(backend: backend, path: "/x"),
                vaultMountPoints: [],
                allowingServerSide: true
            ) == nil, "\(backend)")
        }
    }

    @Test("a local side inside a vault has no record")
    func vault() {
        #expect(SyncRecordPair(
            left: .local("/Volumes/Secret/Notes"),
            right: server,
            vaultMountPoints: ["/Volumes/Secret"],
            allowingServerSide: true
        ) == nil)
    }

    @Test("two local folders are written down exactly as before")
    func localUnchanged() throws {
        let pair = try #require(SyncRecordPair(
            left: .local("/b"),
            right: .local("/a"),
            vaultMountPoints: [],
            allowingServerSide: true
        ))
        #expect(pair.first == "/a")
        #expect(pair.second == "/b")
        #expect(pair.serverFolder == nil)
        #expect(pair.key == Self.m37Key(first: "/a", second: "/b"))
    }

    @Test("a server pair's key names no local pair's folder")
    func keysApart() throws {
        let pair = try #require(SyncRecordPair(
            left: local,
            right: server,
            vaultMountPoints: [],
            allowingServerSide: true
        ))
        let localPair = try #require(SyncRecordPair(
            left: local,
            right: .local(server.path),
            vaultMountPoints: []
        ))
        #expect(pair.key != localPair.key)
    }

    /// An M37 build reads a server pair's record and finds its folder named for it, so its launch
    /// purge leaves the record alone. Decoded through that build's own shapes, and its key computed
    /// by its own formula, rather than through anything this slice wrote.
    @Test("a build that predates server pairs keeps their records at its launch")
    func olderBuildKeeps() throws {
        let fixture = try ServerSyncFixture()
        defer { fixture.cleanup() }
        try fixture.writeLocal("a.txt", "one\n")
        try fixture.sync()

        let directory = fixture.store.directory(of: fixture.pair)
        let data = try Data(contentsOf: directory.appendingPathComponent("record.json"))
        let manifest = try JSONDecoder().decode(M37Manifest.self, from: data)
        #expect(
            Self.m37Key(first: manifest.pair.first, second: manifest.pair.second) == directory.lastPathComponent
        )
        #expect(manifest.versions.keys.sorted() == ["a.txt"])

        let pairObject = try #require(
            (JSONSerialization.jsonObject(with: data) as? [String: Any])?["pair"] as? [String: Any]
        )
        #expect(Set(pairObject.keys) == ["first", "second"])
    }

    @Test("a stamp survives the record exactly, a weak tag and a fraction of a second included")
    func stampRoundTrip() throws {
        let stamp = RemoteFileRevision(
            byteSize: 42,
            modified: Date(timeIntervalSince1970: 1_800_000_123.456_789),
            entityTag: "W/\"abc\""
        )
        let version = SyncRecord.Version(
            file: UUID(),
            byteSize: 42,
            keptAt: Date(timeIntervalSince1970: 7),
            serverRevision: stamp
        )
        let back = try JSONDecoder().decode(
            SyncRecord.Version.self,
            from: JSONEncoder().encode(version)
        )
        #expect(back == version)
        #expect(back.serverRevision?.isSuperseded(by: stamp) == false)
    }

    @Test("a local pair's version is written as M37 wrote it")
    func localVersionUnchanged() throws {
        let version = SyncRecord.Version(
            file: UUID(),
            byteSize: 1,
            keptAt: Date(timeIntervalSince1970: 7)
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(version)) as? [String: Any]
        )
        #expect(Set(object.keys) == ["file", "byteSize", "keptAt"])
    }

    // MARK: - M37's shapes

    private struct M37Pair: Decodable {
        let first: String
        let second: String
    }

    private struct M37Version: Decodable {
        let file: UUID
        let byteSize: Int64
        let keptAt: Date
    }

    private struct M37Manifest: Decodable {
        let pair: M37Pair
        let versions: [String: M37Version]
    }

    private static func m37Key(first: String, second: String) -> String {
        SHA256.hash(data: Data((first + "\0" + second).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
