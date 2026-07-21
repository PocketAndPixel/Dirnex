import Foundation
import Testing

@testable import DirnexCore

/// Where clicking a cloud mount's sidebar row lands, and which mount a given path belongs to
/// (PLAN.md §M10 Phase 1). Discovery and naming live in `CloudStorageMountsTests`.
@Suite("CloudStorageMounts entry")
struct CloudStorageMountEntryTests {
    // MARK: - Where a click lands

    @Test("a mount holding only My Drive opens My Drive, not the mount root")
    func singleVisibleChildIsTheEntryDirectory() throws {
        // The real shape probed 2026-07-21: the mount holds `My Drive` plus dot-directories.
        let temp = try TempTree()
        defer { temp.cleanup() }
        let mount = "Library/CloudStorage/GoogleDrive-someone@gmail.com"
        try temp.makeDir("\(mount)/My Drive")
        try temp.makeDir("\(mount)/.Trash")
        try temp.makeDir("\(mount)/.shortcut-targets-by-id")

        let found = try #require(CloudStorageMounts.mounts(home: temp.root.path).first)
        #expect(found.entryDirectory == temp.vfsPath("\(mount)/My Drive"))
        #expect(found.path == temp.vfsPath(mount))
    }

    @Test("a My Drive that is a symlink to a real folder still counts as the way in")
    func symlinkedEntryDirectoryIsFollowed() throws {
        // Drive in *mirror* mode makes `My Drive` a symlink out to `~/My Drive` (probed), so
        // reading the file type rather than testing for a directory would miss it entirely.
        let temp = try TempTree()
        defer { temp.cleanup() }
        let mount = "Library/CloudStorage/GoogleDrive-someone@gmail.com"
        try temp.makeDir(mount)
        try temp.makeDir("Mirror")
        try temp.symlink("\(mount)/My Drive", to: temp.path("Mirror"))

        let found = try #require(CloudStorageMounts.mounts(home: temp.root.path).first)
        #expect(found.entryDirectory == temp.vfsPath("\(mount)/My Drive"))
    }

    @Test("a mount with two visible children opens at its root so neither is hidden")
    func twoChildrenStayAtTheRoot() throws {
        // An account that also has Shared drives. Descending would silently hide one of them.
        let temp = try TempTree()
        defer { temp.cleanup() }
        let mount = "Library/CloudStorage/GoogleDrive-someone@gmail.com"
        try temp.makeDir("\(mount)/My Drive")
        try temp.makeDir("\(mount)/Shared drives")

        let found = try #require(CloudStorageMounts.mounts(home: temp.root.path).first)
        #expect(found.entryDirectory == temp.vfsPath(mount))
    }

    @Test("a mount that is empty opens at its root")
    func emptyMountEntersItself() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let mount = "Library/CloudStorage/GoogleDrive-someone@gmail.com"
        try temp.makeDir(mount)

        let found = try #require(CloudStorageMounts.mounts(home: temp.root.path).first)
        #expect(found.entryDirectory == temp.vfsPath(mount))
    }

    @Test("a lone visible *file* is not a way in")
    func singleVisibleFileIsNotEntered() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let mount = "Library/CloudStorage/GoogleDrive-someone@gmail.com"
        try temp.makeDir(mount)
        try temp.writeFile("\(mount)/readme.txt", bytes: 4)

        let found = try #require(CloudStorageMounts.mounts(home: temp.root.path).first)
        #expect(found.entryDirectory == temp.vfsPath(mount))
    }

    // MARK: - Which mount a path is in

    @Test("a path inside a mount reports the mount it belongs to")
    func pathInsideAMountFindsIt() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let mount = "Library/CloudStorage/GoogleDrive-someone@gmail.com"
        try temp.makeDir("\(mount)/My Drive/Job")

        let found = CloudStorageMounts.mount(
            containing: temp.vfsPath("\(mount)/My Drive/Job"),
            home: temp.root.path
        )
        #expect(found?.name == "Google Drive")
        #expect(found?.path == temp.vfsPath(mount))
    }

    @Test("the mount root itself is inside its own mount")
    func mountRootFindsItself() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        let mount = "Library/CloudStorage/GoogleDrive-someone@gmail.com"
        try temp.makeDir(mount)

        let found = CloudStorageMounts.mount(containing: temp.vfsPath(mount), home: temp.root.path)
        #expect(found?.path == temp.vfsPath(mount))
    }

    @Test("an ordinary path is in no mount")
    func ordinaryPathHasNoMount() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-someone@gmail.com")
        try temp.makeDir("Dev")

        #expect(
            CloudStorageMounts.mount(containing: temp.vfsPath("Dev"), home: temp.root.path) == nil
        )
    }

    @Test("CloudStorage itself is in no mount")
    func theParentIsNotAMount() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-someone@gmail.com")

        let parent = CloudStorageMounts.cloudStorage(home: temp.root.path)
        #expect(CloudStorageMounts.mount(containing: parent, home: temp.root.path) == nil)
    }

    @Test("a non-local path is never in a mount")
    func remotePathHasNoMount() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Library/CloudStorage/GoogleDrive-someone@gmail.com")

        let remote = VFSPath(backend: .search, path: temp.path("Library/CloudStorage"))
        #expect(CloudStorageMounts.mount(containing: remote, home: temp.root.path) == nil)
    }
}
