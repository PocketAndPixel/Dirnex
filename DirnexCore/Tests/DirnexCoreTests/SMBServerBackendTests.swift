import Foundation
import Testing

@testable import DirnexCore

/// A fake ``SMBShareEnumerating``: the shares it answers, or the status it throws, and how many
/// sessions it was asked for.
final class FakeSMBShareEnumerator: SMBShareEnumerating, @unchecked Sendable {
    var answer: [SMBShare]
    var status: Int32?
    private(set) var calls = 0

    init(shares: [SMBShare] = [], status: Int32? = nil) {
        answer = shares
        self.status = status
    }

    func shares() throws -> [SMBShare] {
        calls += 1
        if let status { throw SMBShareListingError(status: status) }
        return answer
    }
}

/// One SMB server's shares as a pane (PLAN.md §M35).
///
/// The sharepoint dictionary below is what the NAS's SMB plugin answered on 2026-11-04 to
/// `EnumerateShares` as `dirnex-test`, not what the header promises: no `IsHidden`, no
/// `PrinterShare`, a `NetShareTypeStr` the header never names, and an empty comment as `""`.
@Suite("SMB server backend")
struct SMBServerBackendTests {
    private static let server = SMBLocation(host: "nas", username: "dirnex-test")

    private static var realSharepoints: [String: Any] { [
        "home": [
            "AlreadyMounted": false,
            "HasPassword": false,
            "NetCommentStr": "Home directory of dirnex-test",
            "NetShareTypeStr": "Disk"
        ] as [String: Any],
        "media": [
            "AlreadyMounted": false,
            "HasPassword": false,
            "NetCommentStr": "",
            "NetShareTypeStr": "Disk"
        ] as [String: Any],
        "share": [
            "AlreadyMounted": false,
            "HasPassword": false,
            "NetCommentStr": "",
            "NetShareTypeStr": "Disk"
        ] as [String: Any]
    ] }

    private static func root(_ server: SMBLocation = server) -> VFSPath {
        VFSPath(backend: .smbServer(server), path: "/")
    }

    // MARK: - Reading the plugin's answer

    @Test("the NAS's real answer reads as its three disk shares, sorted, comments kept")
    func parsesRealAnswer() {
        let shares = SMBShare.shares(fromSharepoints: Self.realSharepoints)
        #expect(shares == [
            SMBShare(name: "home", comment: "Home directory of dirnex-test"),
            SMBShare(name: "media"),
            SMBShare(name: "share")
        ])
    }

    @Test("hidden, $-suffixed, printer and non-disk shares are left out")
    func leavesOutWhatCannotBeOpened() {
        let shares = SMBShare.shares(fromSharepoints: [
            "Public": ["NetShareTypeStr": "Disk"],
            "Secret": ["IsHidden": true],
            "IPC$": ["NetShareTypeStr": "IPC"],
            "C$": ["NetShareTypeStr": "Disk"],
            "LaserJet": ["PrinterShare": true],
            "Pipe": ["NetShareTypeStr": "IPC"],
            "Visible": ["IsHidden": false, "PrinterShare": false],
            "Broken": "not a dictionary"
        ])
        #expect(shares.map(\.name) == ["Public", "Visible"])
    }

    @Test("names sort the way the Finder sorts them, numbers by value")
    func sortsByNumericValue() {
        let shares = SMBShare.shares(fromSharepoints: [
            "Share 10": [String: Any](),
            "share 2": [String: Any](),
            "Archive": [String: Any]()
        ])
        #expect(shares.map(\.name) == ["Archive", "share 2", "Share 10"])
    }

    // MARK: - Listing

    @Test("the root lists each share as a folder row on the server's own backend")
    func listsSharesAsFolders() throws {
        let enumerator = FakeSMBShareEnumerator(
            shares: SMBShare.shares(fromSharepoints: Self.realSharepoints)
        )
        let backend = SMBServerBackend(server: Self.server, enumerator: enumerator)
        let entries = try backend.listDirectory(at: Self.root())

        #expect(entries.map(\.name) == ["home", "media", "share"])
        #expect(entries.allSatisfy { $0.kind == .directory })
        #expect(entries.allSatisfy { $0.modificationDate == FileEntry.unknownDate })
        #expect(entries.map(\.path) == ["home", "media", "share"].map {
            VFSPath(backend: .smbServer(Self.server), path: "/\($0)")
        })
        #expect(enumerator.calls == 1)
    }

    @Test("a share's own path is not listed here, and asks the server nothing")
    func deeperPathIsNotFound() {
        let enumerator = FakeSMBShareEnumerator(shares: [SMBShare(name: "media")])
        let backend = SMBServerBackend(server: Self.server, enumerator: enumerator)
        let share = VFSPath(backend: .smbServer(Self.server), path: "/media")

        #expect(throws: VFSError.notFound(share)) { try backend.listDirectory(at: share) }
        #expect(enumerator.calls == 0)
    }

    @Test("a path on another server is refused before anything is asked")
    func refusesAnotherServer() {
        let enumerator = FakeSMBShareEnumerator(shares: [SMBShare(name: "media")])
        let backend = SMBServerBackend(server: Self.server, enumerator: enumerator)
        let other = Self.root(SMBLocation(host: "nas", username: "oleg"))

        #expect(throws: VFSError.self) { try backend.listDirectory(at: other) }
        #expect(enumerator.calls == 0)
    }

    @Test("a failed listing keeps an errno and turns a NetFS status into EIO")
    func mapsListingFailures() {
        let backend = SMBServerBackend(
            server: Self.server,
            enumerator: FakeSMBShareEnumerator(status: EHOSTDOWN)
        )
        #expect(throws: VFSError.io(path: Self.root(), code: EHOSTDOWN)) {
            try backend.listDirectory(at: Self.root())
        }

        let restricted = SMBServerBackend(
            server: Self.server,
            enumerator: FakeSMBShareEnumerator(status: -5999)
        )
        #expect(throws: VFSError.io(path: Self.root(), code: EIO)) {
            try restricted.listDirectory(at: Self.root())
        }
    }

    // MARK: - Stat

    @Test("the root stats without a session; a share stats from the listing")
    func statsRootAndShares() throws {
        let enumerator = FakeSMBShareEnumerator(shares: [SMBShare(name: "media")])
        let backend = SMBServerBackend(server: Self.server, enumerator: enumerator)

        let root = try backend.stat(at: Self.root())
        #expect(root.kind == .directory)
        #expect(root.name == "nas")
        #expect(enumerator.calls == 0)

        let media = VFSPath(backend: .smbServer(Self.server), path: "/media")
        #expect(try backend.stat(at: media).kind == .directory)
        #expect(enumerator.calls == 1)

        let gone = VFSPath(backend: .smbServer(Self.server), path: "/photos")
        #expect(throws: VFSError.notFound(gone)) { try backend.stat(at: gone) }

        let deeper = VFSPath(backend: .smbServer(Self.server), path: "/media/films")
        #expect(throws: VFSError.notFound(deeper)) { try backend.stat(at: deeper) }
    }

    // MARK: - What it is

    @Test("read-only, and its id is the server's whatever share the location named")
    func readOnlyAndServerScoped() {
        let backend = SMBServerBackend(
            server: Self.server.share(named: "media"),
            enumerator: FakeSMBShareEnumerator()
        )
        #expect(backend.capabilities == .read)
        #expect(backend.server == Self.server)
        #expect(backend.id == .smbServer(Self.server))
        #expect(backend.connectionDescriptor == "smb://dirnex-test@nas")
    }
}

/// The server half of ``SMBLocation`` and the backend id it keys (PLAN.md §M35).
@Suite("SMB server identity")
struct SMBServerIdentityTests {
    @Test("a server drops the share and keeps host, port and account")
    func serverDropsShare() {
        let share = SMBLocation(host: "nas", share: "media", username: "oleg", port: 4450)
        #expect(share.server == SMBLocation(host: "nas", username: "oleg", port: 4450))
        #expect(share.server.share(named: "home") == SMBLocation(
            host: "nas",
            share: "home",
            username: "oleg",
            port: 4450
        ))
    }

    @Test("the id is the server's URL, and round-trips with a port and an email login")
    func idRoundTrips() {
        let servers = [
            SMBLocation(host: "nas"),
            SMBLocation(host: "nas", username: "dirnex-test"),
            SMBLocation(host: "192.168.1.7", username: "oleg", port: 4450),
            SMBLocation(host: "pc.local", username: "someone@outlook.com")
        ]
        for server in servers {
            let id = VFSBackendID.smbServer(server)
            #expect(id.rawValue == server.url)
            #expect(id.smbServer == server)
            #expect(id.isSMBServer)
        }
        // A share's location keys its server's id: the list, not the share.
        #expect(VFSBackendID.smbServer(SMBLocation(host: "nas", share: "media")).rawValue
            == "smb://nas")
    }

    @Test("an smb:// id naming a share, and every other id, is not a server")
    func otherIdsAreNotServers() {
        #expect(!VFSBackendID("smb://nas/media").isSMBServer)
        #expect(VFSBackendID("smb://nas/media").smbServer == nil)
        #expect(!VFSBackendID.local.isSMBServer)
        #expect(!VFSBackendID("sftp://u@h:22").isSMBServer)
        #expect(!VFSBackendID("smb://").isSMBServer)
    }

    @Test("a server is a remote place that receives nothing")
    func remoteAndReadOnly() {
        let id = VFSBackendID.smbServer(SMBLocation(host: "nas"))
        #expect(id.isRemoteConnection)
        #expect(!id.acceptsUploads)
        #expect(!id.receivesFiles)
        #expect(!id.hasComparableModificationTimes)
    }

    @Test("a share-less endpoint is the server's backend; a share's has none")
    func endpointBackendID() {
        let server = SMBLocation(host: "nas", username: "dirnex-test")
        #expect(ServerEndpoint.smb(server).backendID == .smbServer(server))
        #expect(ServerEndpoint.smb(server.share(named: "media")).backendID == nil)
    }

    @Test("a tab on a server restores by reconnecting, and only with that server's endpoint")
    func restoresLikeAnAccount() {
        let server = SMBLocation(host: "nas", username: "dirnex-test")
        let path = VFSPath(backend: .smbServer(server), path: "/")

        #expect(TabRestorePolicy.requirement(for: path, endpoint: .smb(server))
            == .connection(.smb(server)))
        // Another account's endpoint, or a share's, is not this tab's.
        let other = SMBLocation(host: "nas", username: "oleg")
        #expect(TabRestorePolicy.requirement(for: path, endpoint: .smb(other)) == nil)
        #expect(TabRestorePolicy.requirement(
            for: path,
            endpoint: .smb(server.share(named: "media"))
        ) == nil)
        #expect(TabRestorePolicy.requirement(for: path, endpoint: nil) == nil)
    }

    @Test("a server draws the network-volume glyph and is not searchable")
    func glyphAndSearch() {
        let id = VFSBackendID.smbServer(SMBLocation(host: "nas"))
        let source = LocationSource.of(
            VFSPath(backend: id, path: "/"),
            mounts: [],
            vaultMountPoints: [],
            home: "/Users/u",
            isInternalVolume: { _ in true }
        )
        #expect(source == .networkVolume)
        #expect(SearchRoute.forBackend(id) == .unavailable)
    }
}

/// What a mount's `ENOENT` means once the list has been asked (PLAN.md §M35).
@Suite("SMB share absence")
struct SMBShareAbsenceTests {
    private static let listing = [SMBShare(name: "home"), SMBShare(name: "Media")]

    @Test("listed and refused is a permission; not listed is not offered; no list is unknown")
    func readsTheListing() {
        #expect(SMBShareAbsence.reading(share: "Media", listing: Self.listing) == .notPermitted)
        #expect(SMBShareAbsence.reading(share: "Photos", listing: Self.listing) == .notOffered)
        #expect(SMBShareAbsence.reading(share: "Media", listing: nil) == .unknown)
        #expect(SMBShareAbsence.reading(share: "Media", listing: []) == .notOffered)
    }

    @Test("a name typed in another case is the listed share")
    func comparesWithoutCase() {
        #expect(SMBShareAbsence.reading(share: "media", listing: Self.listing) == .notPermitted)
        #expect(SMBShareAbsence.reading(share: "HOME", listing: Self.listing) == .notPermitted)
    }
}

/// Writing down a place inside a mounted share as a path on the server's list, and finding it again
/// (PLAN.md §M35). Reported 2026-11-04: a tab left inside `media/Movies` came back with only the
/// share rows open and the cursor on the first row.
@Suite("SMB share mounts")
struct SMBShareMountsTests {
    private static let mounts = SMBShareMounts([
        "media": "/Volumes/media",
        "media-old": "/Volumes/media-1",
        "home": "/Volumes/home"
    ])

    @Test("a local path under a mount is spelled through its share")
    func spellsThroughTheShare() {
        #expect(Self.mounts.serverRelativePath(ofLocal: "/Volumes/media/Movies") == "media/Movies")
        #expect(Self.mounts.serverRelativePath(ofLocal: "/Volumes/media/Movies/Crime.mkv")
            == "media/Movies/Crime.mkv")
        #expect(Self.mounts.serverRelativePath(ofLocal: "/Volumes/media") == "media")
    }

    @Test("a mount point holds only what is under it by whole components")
    func wholeComponentsOnly() {
        #expect(Self.mounts.serverRelativePath(ofLocal: "/Volumes/media-1/x") == "media-old/x")
        #expect(Self.mounts.serverRelativePath(ofLocal: "/Volumes/mediaX/x") == nil)
        #expect(Self.mounts.serverRelativePath(ofLocal: "/Users/oleg") == nil)
    }

    @Test("a stored path resolves to its share row, its mount, or waits for the mount")
    func resolves() {
        #expect(Self.mounts.resolve("media") == .shareRow("media"))
        #expect(Self.mounts.resolve("media/Movies/Crime.mkv")
            == .local(.local("/Volumes/media/Movies/Crime.mkv")))
        #expect(Self.mounts.resolve("share/x") == .awaitingMount(share: "share"))
        #expect(Self.mounts.resolve("") == nil)
    }

    @Test("a share mounted somewhere else this time resolves to where it is now")
    func followsTheMountNow() {
        let written = SMBShareMounts(["media": "/Volumes/media"])
            .serverRelativePath(ofLocal: "/Volumes/media/Movies")
        let now = SMBShareMounts(["media": "/Volumes/media-2"])
        #expect(written.flatMap { now.resolve($0) } == .local(.local("/Volumes/media-2/Movies")))
    }
}
