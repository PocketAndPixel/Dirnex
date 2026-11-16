import Foundation
import Testing

@testable import DirnexCore

/// Where a pinned folder lives — the mark in the corner of its folder glyph. A pin outlives its
/// mount, so the mark has to say the same thing whether the share, the vault or the drive is here.
@Suite("Pin source")
struct PinSourceTests {
    private static let home = "/Users/u"
    private static let share = SMBLocation(host: "nas", username: "u").share(named: "media")

    /// The boot disk, an external drive, a share and an unlocked vault.
    private static let mounts: [MountTableEntry] = [
        MountTableEntry(mountPoint: "/", isLocal: true),
        MountTableEntry(mountPoint: "/Volumes/USB", isLocal: true),
        MountTableEntry(mountPoint: "/Volumes/NAS", isLocal: false),
        MountTableEntry(mountPoint: "/Volumes/SecDocs", isLocal: true)
    ]

    private func source(
        _ entry: FavoriteEntry,
        mounts: [MountTableEntry] = Self.mounts,
        vaultMountPoints: [String] = ["/Volumes/SecDocs"],
        vaultVolumeNames: [String] = ["SecDocs", "Taxes"],
        isSymlink: @escaping (String) -> Bool = { _ in false }
    ) -> LocationSource {
        LocationSource.ofPin(
            entry,
            mounts: mounts,
            vaultMountPoints: vaultMountPoints,
            vaultVolumeNames: vaultVolumeNames,
            home: Self.home,
            isInternalVolume: { $0 == "/" },
            isSymlink: isSymlink
        )
    }

    private func pin(_ path: String, endpoint: ServerEndpoint? = nil) -> FavoriteEntry {
        FavoriteEntry(path: .local(path), endpoint: endpoint)
    }

    // MARK: - This Mac's own disk

    @Test("a folder on the boot disk carries no mark")
    func bootDisk() {
        #expect(source(pin("/Users/u/Projects")) == .folder)
        #expect(source(pin("/Volumes")) == .folder)
    }

    /// `/Volumes/Macintosh HD` is a link to `/`, so a pin through it is on the boot disk, not on a
    /// drive that has gone.
    @Test("a pin through the boot volume's link in /Volumes is not a missing drive")
    func bootVolumeLink() {
        let entry = pin("/Volumes/Macintosh HD/Users/u/Projects")
        #expect(source(entry, isSymlink: { $0 == "/Volumes/Macintosh HD" }) == .folder)
    }

    // MARK: - Shares

    @Test("a pin that recorded its share is on the network, mounted or not")
    func recordedShare() {
        let entry = pin("/Volumes/media/TV", endpoint: .smb(Self.share))
        #expect(source(entry) == .networkVolume)
        let mounted = Self.mounts + [MountTableEntry(mountPoint: "/Volumes/media", isLocal: false)]
        #expect(source(entry, mounts: mounted) == .networkVolume)
    }

    @Test("a pin on a mounted share that recorded nothing is still on the network")
    func mountedShareWithoutRecord() {
        #expect(source(pin("/Volumes/NAS/Photos")) == .networkVolume)
    }

    // MARK: - Drives

    @Test("a pin on an external drive is on that drive, plugged in or not")
    func drive() {
        #expect(source(pin("/Volumes/USB/DCIM")) == .externalVolume)
        #expect(
            source(
                pin("/Volumes/USB/DCIM"),
                mounts: [MountTableEntry(mountPoint: "/", isLocal: true)]
            )
                == .externalVolume
        )
        #expect(source(pin("/Volumes/T7")) == .externalVolume)
    }

    // MARK: - Vaults

    @Test("a pin in a vault is in the vault, unlocked or locked")
    func vault() {
        #expect(source(pin("/Volumes/SecDocs/2026")) == .vault)
        #expect(source(pin("/Volumes/Taxes/2026"), vaultMountPoints: []) == .vault)
    }

    @Test("a missing volume whose name no saved vault has is a drive")
    func vaultNamesAreExact() {
        #expect(source(pin("/Volumes/TaxesOld/2026"), vaultMountPoints: []) == .externalVolume)
    }

    // MARK: - Everything else

    @Test("cloud storage, iCloud Drive and the Trash are named by their path")
    func lexicalTerritories() {
        #expect(source(pin("/Users/u/Library/CloudStorage/Dropbox/Photos")) == .cloudStorage)
        #expect(
            source(pin("/Users/u/Library/Mobile Documents/com~apple~CloudDocs/Mail")) == .iCloudDrive
        )
        #expect(source(pin("/Volumes/USB/.Trashes/501/old"), mounts: []) == .trash)
    }

    @Test("a pin on a connected account answers for its backend")
    func remote() {
        let sftp = SFTPLocation(host: "mac", username: "u")
        let ftp = FTPLocation(host: "nas", username: "u")
        let bucket = S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")
        let dav = WebDAVLocation(host: "nas", port: 5006, username: "u")
        let reconnect = ServerEndpoint.sftp(location: sftp, authentication: .password)
        let cases: [(FavoriteEntry, LocationSource)] = [
            (
                FavoriteEntry(path: VFSPath(backend: .sftp(sftp), path: "/srv"), endpoint: reconnect),
                .sftp
            ),
            (FavoriteEntry(path: VFSPath(backend: ftp.backendID, path: "/up")), .ftp),
            (FavoriteEntry(path: VFSPath(backend: .s3(bucket), path: "/photos")), .s3),
            (FavoriteEntry(path: VFSPath(backend: .webDAV(dav), path: "/home")), .webdav),
            (
                FavoriteEntry(
                    path: VFSPath(backend: .archive(forArchiveAt: "/Users/u/a.zip"), path: "/src")
                ),
                .archive
            )
        ]
        for (entry, expected) in cases {
            #expect(source(entry) == expected, "\(entry.path)")
        }
    }
}
