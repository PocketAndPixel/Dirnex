import Foundation
import Testing

@testable import DirnexCore

@Suite("SidebarLocations")
struct PlacesTests {
    // MARK: - Favorites

    @Test("favorites always lead with Home at the given path")
    func favoritesLeadWithHome() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }

        let favorites = SidebarLocations.favorites(home: temp.root.path)
        let home = try #require(favorites.first)
        #expect(home.kind == .home)
        #expect(home.name == "Home")
        #expect(home.path == VFSPath.local(temp.root.path))
    }

    @Test("favorites include only home subfolders that exist on disk")
    func favoritesSkipMissingSubfolders() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        try temp.makeDir("Downloads")
        try temp.makeDir("Documents")
        // No Desktop/Pictures/Music/Movies — those must not appear.

        let favorites = SidebarLocations.favorites(home: temp.root.path)
        let kinds = favorites.map(\.kind)
        #expect(kinds.contains(.downloads))
        #expect(kinds.contains(.documents))
        #expect(!kinds.contains(.desktop))
        #expect(!kinds.contains(.movies))
    }

    @Test("favorites keep Finder-like order: Home, then subfolders as declared")
    func favoritesPreserveOrder() throws {
        let temp = try TempTree()
        defer { temp.cleanup() }
        // Create them out of display order to prove the output order is deliberate.
        try temp.makeDir("Downloads")
        try temp.makeDir("Desktop")
        try temp.makeDir("Documents")

        let kinds = SidebarLocations.favorites(home: temp.root.path).map(\.kind)
        let subset = kinds.filter { [.desktop, .documents, .downloads].contains($0) }
        #expect(subset == [.desktop, .documents, .downloads])
    }

    // MARK: - Volumes (against the real mount table)

    @Test("mounted volumes always include a browsable root filesystem")
    func volumesIncludeRoot() {
        let volumes = SidebarLocations.volumes()
        // Every macOS machine (and CI runner) has a root volume mounted at "/".
        let root = volumes.first { $0.path == VFSPath.local("/") }
        #expect(root != nil)
        #expect(root?.isRoot == true)
    }

    @Test("root filesystem sorts first and is never ejectable")
    func rootSortsFirstAndCannotEject() {
        let volumes = SidebarLocations.volumes()
        #expect(volumes.first?.isRoot == true)
        for volume in volumes where volume.isRoot {
            #expect(!volume.canEject)
        }
    }

    @Test("canEject follows removable/ejectable media, not internal disks")
    func ejectFollowsMediaFlags() {
        // Pure logic over the model — no mounted removable media required in CI.
        let internalDisk = MountedVolume(
            name: "Macintosh HD", path: .local("/"), isRoot: true, isRemovable: false,
            isEjectable: false, isInternal: true, isReadOnly: false,
            totalCapacity: nil, availableCapacity: nil
        )
        let usbStick = MountedVolume(
            name: "USB", path: .local("/Volumes/USB"), isRoot: false, isRemovable: true,
            isEjectable: false, isInternal: false, isReadOnly: false,
            totalCapacity: nil, availableCapacity: nil
        )
        // An external drive (e.g. a USB SSD) commonly reports neither removable nor ejectable,
        // only that it isn't internal — Finder still lets you eject it, and so must we.
        let externalDrive = MountedVolume(
            name: "TRANSCEND", path: .local("/Volumes/TRANSCEND"), isRoot: false,
            isRemovable: false,
            isEjectable: false, isInternal: false, isReadOnly: false,
            totalCapacity: nil, availableCapacity: nil
        )
        #expect(!internalDisk.canEject)
        #expect(usbStick.canEject)
        #expect(externalDrive.canEject)
    }

    @Test("volume symbol splits built-in storage from everything external")
    func symbolFollowsInternalFlag() {
        func volume(isRoot: Bool = false, isInternal: Bool, isRemovable: Bool = false) -> MountedVolume {
            MountedVolume(
                name: "V", path: .local("/Volumes/V"), isRoot: isRoot, isRemovable: isRemovable,
                isEjectable: false, isInternal: isInternal, isReadOnly: false,
                totalCapacity: nil, availableCapacity: nil
            )
        }
        #expect(volume(isRoot: true, isInternal: true).symbolName == "internaldrive")
        #expect(volume(isInternal: true).symbolName == "internaldrive")
        #expect(volume(isInternal: false).symbolName == "externaldrive")
        #expect(volume(isInternal: false, isRemovable: true).symbolName == "externaldrive")
    }

    @Test("every mounted volume names a real SF Symbol")
    func symbolsResolve() {
        // Guards against a typo'd or renamed symbol shipping a blank sidebar row.
        for volume in SidebarLocations.volumes() {
            #expect(["internaldrive", "externaldrive"].contains(volume.symbolName))
        }
    }
}
