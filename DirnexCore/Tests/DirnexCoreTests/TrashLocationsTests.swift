import Foundation
import Testing

@testable import DirnexCore

/// Every path shape here was taken from a real machine (probed 2026-07-21 against `~/.Trash` and a
/// mounted disk image): the boot volume's trash is `~/.Trash`, a mounted volume's is
/// `<volume>/.Trashes/<uid>`, and its `.Trashes` parent is unlistable even by its owner.
@Suite("Trash locations")
struct TrashLocationsTests {
    // MARK: - Where the trashes are

    @Test("the boot volume's trash is ~/.Trash")
    func homeTrashPath() {
        #expect(TrashLocations.homeTrash(home: "/Users/me") == VFSPath.local("/Users/me/.Trash"))
    }

    @Test("a volume's trash is the numbered directory inside its .Trashes container")
    func volumeTrashPath() {
        let trash = TrashLocations.volumeTrash(onVolumeAt: .local("/Volumes/Backup"), uid: 501)
        // Constructed, never enumerated: `.Trashes` is mode d-wx--x--t and cannot be listed to
        // find this, and `FileManager`'s trash lookup throws "feature not supported" for a volume
        // with nothing trashed on it yet (both probed).
        #expect(trash == VFSPath.local("/Volumes/Backup/.Trashes/501"))
    }

    @Test("iCloud Drive's trash sits beside the containers, with no numbered directory")
    func iCloudTrashPath() {
        // Probed 2026-07-21: a folder deleted from iCloud Drive lands here, *not* in `~/.Trash` —
        // and it is a sibling of `com~apple~CloudDocs`, not a child of it.
        #expect(
            TrashLocations.iCloudTrash(home: "/Users/me")
                == VFSPath.local("/Users/me/Library/Mobile Documents/.Trash")
        )
    }

    @Test("a provider mount's trash sits at its root, with no numbered directory")
    func cloudStorageTrashPath() {
        // Probed 2026-07-22: a file deleted from Google Drive lands here, not in `~/.Trash`. Same
        // shape as iCloud's — and all three carry the `com.apple.fileprovider.trash` marker xattr
        // that `~/.Trash` does not.
        let mount = VFSPath.local("/Users/me/Library/CloudStorage/GoogleDrive-me@gmail.com")
        #expect(
            TrashLocations.cloudStorageTrash(inMountAt: mount)
                == VFSPath.local("/Users/me/Library/CloudStorage/GoogleDrive-me@gmail.com/.Trash")
        )
    }

    // MARK: - Standing in the Trash

    @Test("the home trash and everything under it reads as inside the Trash")
    func homeTrashIsInside() {
        let home = "/Users/me"
        #expect(TrashLocations.isInsideTrash(.local("/Users/me/.Trash"), home: home))
        #expect(TrashLocations.isInsideTrash(.local("/Users/me/.Trash/notes.txt"), home: home))
        #expect(
            TrashLocations.isInsideTrash(.local("/Users/me/.Trash/folder/deep/file"), home: home)
        )
    }

    @Test("an ordinary folder is not the Trash")
    func ordinaryPathsAreNotInside() {
        let home = "/Users/me"
        #expect(!TrashLocations.isInsideTrash(.local("/Users/me"), home: home))
        #expect(!TrashLocations.isInsideTrash(.local("/Users/me/Documents"), home: home))
        // A sibling whose name merely starts with the trash's — the reason this is a component
        // walk and not a string prefix test.
        #expect(!TrashLocations.isInsideTrash(.local("/Users/me/.Trashcan"), home: home))
        // Another account's trash is not this one's home trash, but see below: it is still *a*
        // trash by the volume rule only when it is numbered under `.Trashes`.
        #expect(!TrashLocations.isInsideTrash(.local("/Users/other/.Trash"), home: home))
    }

    @Test("iCloud Drive's trash and everything under it reads as inside the Trash")
    func iCloudTrashIsInside() {
        let home = "/Users/me"
        let trash = "/Users/me/Library/Mobile Documents/.Trash"
        #expect(TrashLocations.isInsideTrash(.local(trash), home: home))
        #expect(TrashLocations.isInsideTrash(.local(trash + "/temp/scan.pdf"), home: home))
        // The containers beside it are ordinary browsable folders, trash-adjacent or not.
        #expect(!TrashLocations.isInsideTrash(
            .local("/Users/me/Library/Mobile Documents/com~apple~CloudDocs"), home: home
        ))
    }

    @Test("a provider mount's trash and everything under it reads as inside the Trash")
    func cloudStorageTrashIsInside() {
        let home = "/Users/me"
        let mount = "/Users/me/Library/CloudStorage/GoogleDrive-me@gmail.com"
        #expect(TrashLocations.isInsideTrash(.local(mount + "/.Trash"), home: home))
        #expect(TrashLocations.isInsideTrash(.local(mount + "/.Trash/jmeter.log"), home: home))
        #expect(TrashLocations.isInsideTrash(.local(mount + "/.Trash/deep/folder/x"), home: home))
        // A second account is a second mount with a trash of its own.
        let other = "/Users/me/Library/CloudStorage/GoogleDrive-other@gmail.com"
        #expect(TrashLocations.isInsideTrash(.local(other + "/.Trash/notes.txt"), home: home))
        // The synced content beside it is an ordinary browsable folder.
        #expect(!TrashLocations.isInsideTrash(.local(mount + "/My Drive"), home: home))
    }

    @Test("a .Trash the user made inside their own Drive folder is not a trash")
    func nestedCloudStorageTrashIsNotInside() {
        // The mount's trash is exactly one level below the CloudStorage root. A folder the user
        // named `.Trash` deeper in their Drive is ordinary content, and reading it as a trash would
        // silently turn F8 there into a permanent delete — the expensive direction to be wrong in.
        let home = "/Users/me"
        let mount = "/Users/me/Library/CloudStorage/GoogleDrive-me@gmail.com"
        #expect(!TrashLocations.isInsideTrash(.local(mount + "/My Drive/.Trash"), home: home))
        #expect(!TrashLocations.isInsideTrash(.local(mount + "/My Drive/.Trash/x.txt"), home: home))
        // And the CloudStorage root itself has no trash — a `.Trash` there belongs to no mount.
        #expect(!TrashLocations.isInsideTrash(
            .local("/Users/me/Library/CloudStorage/.Trash"), home: home
        ))
    }

    @Test("a volume trash counts at any depth, for any user's numbered directory")
    func volumeTrashIsInside() {
        #expect(TrashLocations.isInsideTrash(.local("/Volumes/Backup/.Trashes/501")))
        #expect(TrashLocations.isInsideTrash(.local("/Volumes/Backup/.Trashes/501/old.txt")))
        // Deliberately generous: another user's trash on that volume qualifies too. A false
        // positive costs one confirmation dialog; a false negative is a delete that silently
        // does nothing.
        #expect(TrashLocations.isInsideTrash(.local("/Volumes/Backup/.Trashes/502/old.txt")))
    }

    @Test("a .Trashes container without a numbered directory under it is not a trash")
    func bareTrashesContainerIsNotInside() {
        // The container is a holder of per-user trashes, not a trash — and it can't be listed
        // anyway. A folder someone happens to have named `.Trashes` must not disarm the Trash.
        #expect(!TrashLocations.isInsideTrash(.local("/Volumes/Backup/.Trashes")))
        #expect(!TrashLocations.isInsideTrash(.local("/Volumes/Backup/.Trashes/notes.txt")))
        #expect(!TrashLocations.isInsideTrash(.local("/Volumes/Backup/.Trashes/501x/notes.txt")))
    }

    @Test("a path on another backend is never inside the Trash")
    func otherBackendsAreNeverInside() {
        // An SFTP or archive path can look exactly like a local trash path and means nothing of
        // the sort — and those backends have no Trash to begin with.
        #expect(!TrashLocations.isInsideTrash(VFSPath(backend: .search, path: "/Users/me/.Trash")))
        #expect(
            !TrashLocations.isInsideTrash(
                VFSPath(backend: VFSBackendID("sftp:me@host:22"), path: "/Volumes/B/.Trashes/501")
            )
        )
    }

    // MARK: - Enumerating what exists

    @Test("only trash directories that exist are enumerated, home first")
    func enumeratesExistingTrashes() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir(".Trash")
        try temp.makeDir("Library/Mobile Documents/.Trash")
        try temp.makeDir("Volumes/Backup/.Trashes/501")
        // A volume that exists but has had nothing trashed on it: no `.Trashes/<uid>`, so it
        // contributes nothing rather than a dead row.
        try temp.makeDir("Volumes/Empty")

        let volumes = [
            volume(at: temp.path("Volumes/Backup"), name: "Backup"),
            volume(at: temp.path("Volumes/Empty"), name: "Empty")
        ]
        let directories = SidebarLocations.trashDirectories(
            home: temp.root.path,
            volumes: volumes,
            uid: 501
        )
        #expect(
            directories == [
                VFSPath.local(temp.path(".Trash")),
                VFSPath.local(temp.path("Library/Mobile Documents/.Trash")),
                VFSPath.local(temp.path("Volumes/Backup/.Trashes/501"))
            ]
        )
    }

    @Test("every provider mount contributes its own trash, one per account")
    func enumeratesCloudStorageTrashes() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir(".Trash")
        let cloud = "Library/CloudStorage"
        try temp.makeDir("\(cloud)/GoogleDrive-a@gmail.com/.Trash")
        try temp.makeDir("\(cloud)/GoogleDrive-b@gmail.com/.Trash")
        // A mount that has had nothing deleted on it yet has no `.Trash` and contributes nothing —
        // the same "only what exists" rule the volumes follow. Probed: a freshly connected Drive
        // account mounts without one.
        try temp.makeDir("\(cloud)/Dropbox")

        let directories = SidebarLocations.trashDirectories(
            home: temp.root.path,
            volumes: [],
            uid: 501
        )
        #expect(
            directories == [
                VFSPath.local(temp.path(".Trash")),
                VFSPath.local(temp.path("\(cloud)/GoogleDrive-a@gmail.com/.Trash")),
                VFSPath.local(temp.path("\(cloud)/GoogleDrive-b@gmail.com/.Trash"))
            ]
        )
    }

    @Test("a Mac with no sync client contributes no provider trashes")
    func noCloudStorageDirectoryIsNotAnError() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir(".Trash")
        // `~/Library/CloudStorage` does not exist at all until some provider creates it.
        let directories = SidebarLocations.trashDirectories(
            home: temp.root.path,
            volumes: [],
            uid: 501
        )
        #expect(directories == [VFSPath.local(temp.path(".Trash"))])
    }

    @Test("the boot volume is skipped so the home trash is never listed twice")
    func rootVolumeIsSkipped() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir(".Trash")
        // The root volume carries a numbered trash of its own; it is either absent or another
        // user's, and this user's boot-volume trash is `~/.Trash`, already accounted for. Probed:
        // FileManager resolves the trash for `/`, for `/System/Volumes/Data` and for the
        // `/Volumes/Macintosh HD` symlink all to `~/.Trash`.
        try temp.makeDir("root/.Trashes/501")

        let directories = SidebarLocations.trashDirectories(
            home: temp.root.path,
            volumes: [volume(at: temp.path("root"), name: "Macintosh HD", isRoot: true)],
            uid: 501
        )
        #expect(directories == [VFSPath.local(temp.path(".Trash"))])
    }

    @Test("each user sees only their own numbered trash on a volume")
    func otherUsersTrashIsNotEnumerated() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Volumes/Backup/.Trashes/502")

        let directories = SidebarLocations.trashDirectories(
            home: temp.root.path,
            volumes: [volume(at: temp.path("Volumes/Backup"), name: "Backup")],
            uid: 501
        )
        // 502's trash is unreadable to us and none of our business — `isInsideTrash` is generous
        // about it (a delete there must still be permanent) but the listing is not.
        #expect(directories.isEmpty)
    }

    // MARK: - Helpers

    private func volume(at path: String, name: String, isRoot: Bool = false) -> MountedVolume {
        MountedVolume(
            name: name,
            path: .local(path),
            isRoot: isRoot,
            isRemovable: false,
            isEjectable: false,
            isInternal: false,
            isReadOnly: false,
            totalCapacity: nil,
            availableCapacity: nil
        )
    }
}
