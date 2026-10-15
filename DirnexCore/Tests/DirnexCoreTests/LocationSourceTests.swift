import Foundation
import Testing

@testable import DirnexCore

/// Where a tab's listing comes from — the glyph its chip draws — and the mount table that answers it
/// for a local path.
@Suite("Location source")
struct LocationSourceTests {
    private static let home = "/Users/u"

    /// The boot disk, its hidden system volumes, an external drive, a share and a vault — every kind
    /// of mount the classifier has to tell apart.
    private static let mounts: [MountTableEntry] = [
        MountTableEntry(mountPoint: "/", isLocal: true),
        MountTableEntry(mountPoint: "/dev", isLocal: true, isBrowsable: false),
        MountTableEntry(mountPoint: "/System/Volumes/Data", isLocal: true, isBrowsable: false),
        MountTableEntry(mountPoint: "/Volumes/USB", isLocal: true),
        MountTableEntry(mountPoint: "/Volumes/Second", isLocal: true),
        MountTableEntry(mountPoint: "/Volumes/NAS", isLocal: false),
        MountTableEntry(mountPoint: "/Volumes/SecDocs", isLocal: true)
    ]

    /// Which mount points answer `volumeIsInternal`; the rest are external, as a disk image is.
    private static let internalVolumes: Set = ["/", "/System/Volumes/Data", "/Volumes/Second"]

    private func source(_ path: VFSPath, vaults: [String] = ["/Volumes/SecDocs"]) -> LocationSource {
        LocationSource.of(
            path,
            mounts: Self.mounts,
            vaultMountPoints: vaults,
            home: Self.home,
            isInternalVolume: { Self.internalVolumes.contains($0) }
        )
    }

    // MARK: - Local paths

    @Test("a folder on the boot disk, or on a second internal volume, is a folder")
    func bootDisk() {
        #expect(source(.local("/")) == .folder)
        #expect(source(.local("/Users/u/Downloads")) == .folder)
        #expect(source(.local("/System/Volumes/Data/Users")) == .folder)
        #expect(source(.local("/Volumes/Second/Projects")) == .folder)
    }

    @Test("a volume that is neither internal nor one Finder lists is not called a drive")
    func hiddenSystemMount() {
        #expect(source(.local("/dev")) == .folder)
    }

    @Test("an external drive, and a vault that is locked, are external volumes")
    func externalDrive() {
        #expect(source(.local("/Volumes/USB")) == .externalVolume)
        #expect(source(.local("/Volumes/USB/DCIM/100APPLE")) == .externalVolume)
        // Locked, it is only a disk image someone else attached.
        #expect(source(.local("/Volumes/SecDocs/taxes"), vaults: []) == .externalVolume)
    }

    @Test("a mounted share is a network volume, on whole path components")
    func share() {
        #expect(source(.local("/Volumes/NAS")) == .networkVolume)
        #expect(source(.local("/Volumes/NAS/Photos/2026")) == .networkVolume)
        // A sibling whose name merely starts with the share's is on the boot disk.
        #expect(source(.local("/Volumes/NASBackup")) == .folder)
    }

    @Test("an unlocked vault is a vault, though its volume is a disk image")
    func vault() {
        #expect(source(.local("/Volumes/SecDocs")) == .vault)
        #expect(source(.local("/Volumes/SecDocs/taxes/2026")) == .vault)
    }

    @Test("a cloud provider's mount, and anywhere under it, is cloud storage")
    func cloudStorage() {
        #expect(
            source(.local("/Users/u/Library/CloudStorage/GoogleDrive-a@b.com/My Drive")) == .cloudStorage
        )
        #expect(source(.local("/Users/u/Library/CloudStorage/Dropbox")) == .cloudStorage)
    }

    @Test("CloudDocs and an app's library are both iCloud Drive")
    func iCloudFolders() {
        let documents = "/Users/u/Library/Mobile Documents"
        #expect(source(.local(documents + "/com~apple~CloudDocs/Drafts")) == .iCloudDrive)
        #expect(source(.local(documents + "/com~apple~Pages/Documents")) == .iCloudDrive)
    }

    @Test("a folder inside a trash directory is the Trash, wherever that trash is")
    func trashFolders() {
        #expect(source(.local("/Users/u/.Trash/old")) == .trash)
        #expect(source(.local("/Volumes/USB/.Trashes/501/old")) == .trash)
        #expect(source(.local("/Users/u/Library/CloudStorage/Dropbox/.Trash/old")) == .trash)
    }

    // MARK: - Other backends

    @Test("each backend that is a source of its own answers for itself")
    func backends() {
        let sftp = SFTPLocation(host: "mac", username: "u")
        let ftp = FTPLocation(host: "nas", username: "u")
        let bucket = S3Location(host: "h", bucket: "b", region: "r", accessKeyID: "k")
        let account = S3Account(host: "h", region: "r", accessKeyID: "k")
        let cases: [(VFSPath, LocationSource)] = [
            (VFSPath(backend: .trash, path: "/"), .trash),
            (ICloudLocation.mergedPath, .iCloudDrive),
            (VFSPath(backend: .photos, path: "/Albums"), .photos),
            (VFSPath(backend: .archive(forArchiveAt: "/Users/u/pkg.zip"), path: "/inner"), .archive),
            (VFSPath(backend: .sftp(sftp), path: "/srv"), .sftp),
            (VFSPath(backend: ftp.backendID, path: "/share"), .ftp),
            (VFSPath(backend: .s3(bucket), path: "/photos"), .s3),
            (VFSPath(backend: .s3Account(account), path: "/"), .s3)
        ]
        for (path, expected) in cases {
            #expect(source(path) == expected, "\(path)")
        }
    }

    @Test("Recents is told apart from every other results listing")
    func results() {
        #expect(source(SidebarPlaceLocator.recentsPath) == .recents)
        #expect(source(VFSPath(backend: .search, path: "/invoice")) == .search)
    }

    @Test("an archive opened from a share is still an archive")
    func archiveOnAShare() {
        let path = VFSPath(backend: .archive(forArchiveAt: "/Volumes/NAS/backup.zip"), path: "/")
        #expect(source(path) == .archive)
    }

    // MARK: - The mount table

    @Test("a path is on the deepest mount that holds it")
    func deepestMount() {
        #expect(
            MountTable.entry(containing: "/Volumes/NAS/a", in: Self.mounts)?.mountPoint == "/Volumes/NAS"
        )
        #expect(
            MountTable.entry(containing: "/Volumes/NAS", in: Self.mounts)?.mountPoint == "/Volumes/NAS"
        )
        #expect(MountTable.entry(containing: "/Volumes", in: Self.mounts)?.mountPoint == "/")
        #expect(MountTable.entry(containing: "/Users/u", in: []) == nil)
    }

    @Test("this Mac's own mount table has the boot disk on it, local and browsable")
    func liveTable() throws {
        let root = try #require(MountTable.current().first { $0.mountPoint == "/" })
        #expect(root.isLocal)
        #expect(root.isBrowsable)
        #expect(MountTable.entry(containing: NSHomeDirectory(), in: MountTable.current()) != nil)
    }
}
