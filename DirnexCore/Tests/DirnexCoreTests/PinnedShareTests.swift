import Foundation
import Testing

@testable import DirnexCore

/// How a pin on a share that is not mounted finds its way back. Reported 2026-11-10: a pin inside a
/// share Dirnex had unmounted on quit raised "moved or deleted" and offered to remove it.
@Suite("A pin on a share")
struct PinnedShareTests {
    private static let tv = VFSPath.local("/Volumes/media/TV")
    private static let server = SMBLocation(host: "nas", username: "oleg")
    private static let notALink: @Sendable (String) -> Bool = { _ in false }

    private static func saved(_ name: String, _ endpoint: ServerEndpoint) -> ServerConnection {
        ServerConnection(name: name, endpoint: endpoint)
    }

    private static func volume(
        of path: VFSPath,
        mounted: [String] = ["/"],
        isSymlink: (String) -> Bool = notALink
    ) -> String? {
        PinnedShare.unmountedVolume(
            of: path,
            mounted: mounted.map { MountTableEntry(mountPoint: $0, isLocal: $0 == "/") },
            isSymlink: isSymlink
        )
    }

    // MARK: - Which volume is missing

    @Test("a folder on a volume nothing is mounted at needs that volume")
    func absentVolumeIsNamed() {
        #expect(Self.volume(of: Self.tv) == "media")
        #expect(Self.volume(of: .local("/Volumes/media")) == "media")
    }

    @Test("a folder missing from a mounted volume is really gone")
    func mountedVolumeNeedsNothing() {
        #expect(Self.volume(of: Self.tv, mounted: ["/", "/Volumes/media"]) == nil)
    }

    @Test("a volume of a similar name does not count as mounted")
    func wholeNamesOnly() {
        #expect(Self.volume(of: Self.tv, mounted: ["/", "/Volumes/media-1"]) == "media")
    }

    /// `/Volumes/Macintosh HD` is a link to `/` on every Mac, with no mount table entry of its own.
    @Test("the boot volume's link in /Volumes is not an unmounted share")
    func bootVolumeLinkIsNotAShare() {
        let deleted = VFSPath.local("/Volumes/Macintosh HD/Users/oleg/Gone")
        #expect(Self.volume(of: deleted, isSymlink: { $0 == "/Volumes/Macintosh HD" }) == nil)
    }

    @Test("a path outside /Volumes, or /Volumes itself, needs no volume")
    func onlyUnderVolumes() {
        #expect(Self.volume(of: .local("/Users/oleg/Gone")) == nil)
        #expect(Self.volume(of: .local("/Volumes")) == nil)
        #expect(Self.volume(of: .local("/Volumesque/media/TV")) == nil)
    }

    @Test("a server folder spelled like a volume is not one")
    func onlyLocalPaths() {
        let location = SFTPLocation(host: "example.com", username: "oleg")
        #expect(Self.volume(of: VFSPath(backend: .sftp(location), path: "/Volumes/media/TV")) == nil)
    }

    // MARK: - Which shares can bring it back

    @Test("a pin that recorded its share has that one answer")
    func recordedShareIsTheAnswer() {
        let share = Self.server.share(named: "media")
        let pin = FavoriteEntry(name: "TV", path: Self.tv, endpoint: .smb(share))
        let other = Self.saved("Other", .smb(SMBLocation(host: "office", username: "oleg")))
        #expect(PinnedShare.candidates(for: pin, volume: "media", saved: [other]) == [share])
    }

    @Test("an older pin tries a saved share of that name, then saved servers in sidebar order")
    func olderPinTriesSavedServers() {
        let testAccount = SMBLocation(host: "nas", username: "dirnex-test")
        let named = SMBLocation(host: "office", share: "Media", username: "oleg")
        let saved = [
            Self.saved("SMB", .smb(Self.server)),
            Self.saved("SMB DT", .smb(testAccount)),
            Self.saved("Office", .smb(named))
        ]
        let pin = FavoriteEntry(path: Self.tv)
        #expect(PinnedShare.candidates(for: pin, volume: "media", saved: saved) == [
            named,
            Self.server.share(named: "media"),
            testAccount.share(named: "media")
        ])
    }

    @Test("a saved share of another name, and a saved server of another protocol, are not asked")
    func unrelatedSavedServersAreLeftOut() {
        let sftp = ServerEndpoint.sftp(
            location: SFTPLocation(host: "nas", username: "oleg"),
            authentication: .key(identityFile: "/Users/oleg/.ssh/id_ed25519")
        )
        let saved = [
            Self.saved("Home", .smb(Self.server.share(named: "home"))),
            Self.saved("SFTP", sftp)
        ]
        #expect(PinnedShare.candidates(
            for: FavoriteEntry(path: Self.tv),
            volume: "media",
            saved: saved
        ).isEmpty)
    }

    /// A pin holding a server with no share says nothing about which share to mount.
    @Test("a recorded endpoint that names no share falls back to the saved servers")
    func shareLessEndpointIsNotAnAnswer() {
        let pin = FavoriteEntry(name: "TV", path: Self.tv, endpoint: .smb(Self.server))
        let saved = [Self.saved("SMB", .smb(Self.server))]
        #expect(PinnedShare.candidates(for: pin, volume: "media", saved: saved) == [
            Self.server.share(named: "media")
        ])
    }

    // MARK: - Where it lands

    @Test("the folder is found under wherever the share mounted")
    func landsUnderTheMountPoint() {
        #expect(
            PinnedShare.path(Self.tv, onMountPoint: "/Volumes/media-1") == .local(
                "/Volumes/media-1/TV"
            )
        )
        #expect(PinnedShare.path(
            .local("/Volumes/media/TV/My Show"),
            onMountPoint: "/Volumes/media"
        ) == .local("/Volumes/media/TV/My Show"))
    }

    @Test("a pin on the share's own root lands on the mount point")
    func rootPinLandsOnTheMountPoint() {
        #expect(PinnedShare.path(.local("/Volumes/media"), onMountPoint: "/Volumes/media-1") == .local(
            "/Volumes/media-1"
        ))
    }

    // MARK: - What the pin keeps

    @Test("mounting writes the share onto an older pin, in place and under its own name")
    func recordingKeepsNameAndPosition() throws {
        var favorites = Favorites(entries: [
            FavoriteEntry(path: .local("/Users/oleg/Dev")),
            FavoriteEntry(name: "Shows", path: Self.tv),
            FavoriteEntry(path: .local("/Users/oleg"))
        ])
        let share = Self.server.share(named: "media")

        let changed = favorites.recordShare(share, for: Self.tv)

        #expect(changed)
        #expect(favorites.entries.map(\.name) == ["Dev", "Shows", "oleg"])
        #expect(favorites.entries[1].serverEndpoint == .smb(share))
    }

    @Test("a pin that already knows its share is left alone")
    func recordingNeverOverwrites() {
        let recorded = Self.server.share(named: "media")
        var favorites = Favorites(entries: [
            FavoriteEntry(name: "TV", path: Self.tv, endpoint: .smb(recorded))
        ])
        let changed = favorites.recordShare(
            SMBLocation(host: "office", share: "media"),
            for: Self.tv
        )
        #expect(!changed)
        #expect(favorites.entries[0].serverEndpoint == .smb(recorded))
    }

    @Test("recording for a path that is not pinned changes nothing")
    func recordingNeedsAPin() {
        var favorites = Favorites(entries: [FavoriteEntry(path: .local("/Users/oleg/Dev"))])
        let changed = favorites.recordShare(Self.server.share(named: "media"), for: Self.tv)
        #expect(!changed)
        #expect(favorites.entries[0].serverEndpoint == nil)
    }

    @Test("a pin's share survives the store")
    func shareRoundTrips() throws {
        let share = Self.server.share(named: "media")
        let favorites = Favorites(entries: [
            FavoriteEntry(name: "TV", path: Self.tv, endpoint: .smb(share))
        ])
        let decoded = try JSONDecoder().decode(
            Favorites.self,
            from: JSONEncoder().encode(favorites)
        )
        #expect(decoded.entries[0].serverEndpoint == .smb(share))
        #expect(decoded.entries[0].path == Self.tv)
    }

    // MARK: - A dragged row

    private func row(_ path: VFSPath) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: .directory,
            byteSize: 0,
            modificationDate: FileEntry.unknownDate,
            creationDate: FileEntry.unknownDate,
            isHidden: false,
            permissions: nil,
            inode: 0,
            symlinkDestination: nil
        )
    }

    @Test("a folder dragged in from a mounted share remembers the share")
    func draggedRowKeepsItsShare() throws {
        let share = Self.server.share(named: "media")
        let pin = try #require(FavoriteEntry(draggedRow: row(Self.tv), endpoint: .smb(share)))
        #expect(pin.path == Self.tv)
        #expect(pin.serverEndpoint == .smb(share))
    }

    @Test("a local row keeps no endpoint that is not a share")
    func draggedRowDropsOtherEndpoints() throws {
        let pin = try #require(FavoriteEntry(draggedRow: row(Self.tv), endpoint: .smb(Self.server)))
        #expect(pin.serverEndpoint == nil)
    }
}
