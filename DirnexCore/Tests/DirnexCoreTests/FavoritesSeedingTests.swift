import Foundation
import Testing

@testable import DirnexCore

@Suite("Favorites seeding")
struct FavoritesSeedingTests {
    private func path(_ raw: String) -> VFSPath { .local(raw) }

    private func place(_ name: String, _ raw: String, _ kind: FavoritePlace.Kind) -> FavoritePlace {
        FavoritePlace(name: name, path: path(raw), kind: kind)
    }

    // MARK: - Converting a place into a pin

    @Test("a place is pinned under its place name, not its folder name")
    func entryFromPlaceKeepsPlaceName() {
        // The case that matters: Home's last path component is the account name, so the generic
        // FavoriteEntry(path:) would label this row "oleg".
        let home = FavoriteEntry(place: place("Home", "/Users/oleg", .home))
        #expect(home.name == "Home")
        #expect(home.path == path("/Users/oleg"))

        let downloads = FavoriteEntry(place: place("Downloads", "/Users/oleg/Downloads", .downloads))
        #expect(downloads.name == "Downloads")
    }

    // MARK: - Prepending

    @Test("prepend puts the seeded entries ahead of existing pins, both orders preserved")
    func prependLeadsWithSeed() {
        var favorites = Favorites(entries: [
            FavoriteEntry(name: "Work", path: path("/Users/me/Projects")),
            FavoriteEntry(name: "Scratch", path: path("/tmp/scratch"))
        ])
        let changed = favorites.prepend([
            FavoriteEntry(name: "Home", path: path("/Users/me")),
            FavoriteEntry(name: "Documents", path: path("/Users/me/Documents"))
        ])

        #expect(changed)
        #expect(favorites.entries.map(\.name) == ["Home", "Documents", "Work", "Scratch"])
    }

    @Test("a path in both lists lands at the seeded position under the seeded name")
    func prependCollisionFavorsTheSeed() {
        // The user pinned Downloads under a custom label; seeding must reclaim it as the standard
        // row rather than leaving "Dl" stranded above the seeded block or duplicating the path.
        var favorites = Favorites(entries: [
            FavoriteEntry(name: "Dl", path: path("/Users/me/Downloads")),
            FavoriteEntry(name: "Work", path: path("/Users/me/Projects"))
        ])
        favorites.prepend([
            FavoriteEntry(name: "Home", path: path("/Users/me")),
            FavoriteEntry(name: "Downloads", path: path("/Users/me/Downloads"))
        ])

        #expect(favorites.entries.map(\.name) == ["Home", "Downloads", "Work"])
        // Pinned exactly once — the collision resolved, it did not duplicate.
        let downloadsRows = favorites.entries.filter { $0.path == path("/Users/me/Downloads") }
        #expect(downloadsRows.count == 1)
    }

    @Test("prepend reports no change when it would rewrite the list identically")
    func prependReportsNoChange() {
        let seeded = [
            FavoriteEntry(name: "Home", path: path("/Users/me")),
            FavoriteEntry(name: "Documents", path: path("/Users/me/Documents"))
        ]
        var favorites = Favorites(entries: seeded)
        let changed = favorites.prepend(seeded)

        #expect(!changed)
        #expect(favorites.entries.map(\.name) == ["Home", "Documents"])
    }

    @Test("prepending onto an empty favorites is just the seed")
    func prependOntoEmpty() {
        var favorites = Favorites()
        let changed = favorites.prepend([FavoriteEntry(name: "Home", path: path("/Users/me"))])

        #expect(changed)
        #expect(favorites.entries.map(\.path) == [path("/Users/me")])
    }

    @Test("prepending nothing leaves the list untouched")
    func prependEmptySeed() {
        var favorites = Favorites(entries: [FavoriteEntry(name: "Work", path: path("/p"))])
        let changed = favorites.prepend([])

        #expect(!changed)
        #expect(favorites.entries.map(\.name) == ["Work"])
    }

    @Test("an already-pinned path moves up when seeded, and is reported as a change")
    func prependMovesExistingPathToTheFront() {
        var favorites = Favorites(entries: [
            FavoriteEntry(name: "Work", path: path("/Users/me/Projects")),
            FavoriteEntry(name: "Home", path: path("/Users/me"))
        ])
        let changed = favorites.prepend([FavoriteEntry(name: "Home", path: path("/Users/me"))])

        #expect(changed)
        #expect(favorites.entries.map(\.name) == ["Home", "Work"])
    }

    // MARK: - Inserting at a position (the drop half of drag-and-drop)

    @Test("insert places a new pin at the given index")
    func insertAtIndex() {
        var favorites = Favorites(entries: [
            FavoriteEntry(name: "A", path: path("/a")),
            FavoriteEntry(name: "C", path: path("/c"))
        ])
        let changed = favorites.insert(FavoriteEntry(name: "B", path: path("/b")), at: 1)

        #expect(changed)
        #expect(favorites.entries.map(\.name) == ["A", "B", "C"])
    }

    @Test("insert clamps an out-of-range index to the ends")
    func insertClamps() {
        var high = Favorites(entries: [FavoriteEntry(name: "A", path: path("/a"))])
        high.insert(FavoriteEntry(name: "Z", path: path("/z")), at: 99)
        #expect(high.entries.map(\.name) == ["A", "Z"])

        var low = Favorites(entries: [FavoriteEntry(name: "A", path: path("/a"))])
        low.insert(FavoriteEntry(name: "Z", path: path("/z")), at: -5)
        #expect(low.entries.map(\.name) == ["Z", "A"])
    }

    @Test("inserting an already-pinned path moves it and keeps its user-given name")
    func insertRepositionsInsteadOfDuplicating() {
        // Dragging in a folder that is already in the sidebar is a reposition — and a custom label
        // on it has to survive the drag, so the dropped entry's own name must not overwrite it.
        var favorites = Favorites(entries: [
            FavoriteEntry(name: "Work", path: path("/Users/me/Projects")),
            FavoriteEntry(name: "A", path: path("/a")),
            FavoriteEntry(name: "B", path: path("/b"))
        ])
        let changed = favorites.insert(FavoriteEntry(path: path("/Users/me/Projects")), at: 2)

        #expect(changed)
        #expect(favorites.entries.map(\.name) == ["A", "B", "Work"])
        #expect(favorites.entries.count == 3)
    }

    @Test("insert reports no change when the entry is already at that position")
    func insertReportsNoChange() {
        var favorites = Favorites(entries: [
            FavoriteEntry(name: "A", path: path("/a")),
            FavoriteEntry(name: "B", path: path("/b"))
        ])
        let changed = favorites.insert(FavoriteEntry(name: "A", path: path("/a")), at: 0)

        #expect(!changed)
        #expect(favorites.entries.map(\.name) == ["A", "B"])
    }

    // MARK: - Classifying a path back to a standard kind

    @Test("standard home folders classify by path, with no disk access")
    func standardKindMapsHomeFolders() {
        // Deliberately a home that does not exist: the mapping must be pure.
        let home = "/Users/nobody-here"
        #expect(SidebarLocations.standardKind(for: path(home), home: home) == .home)
        #expect(SidebarLocations.standardKind(for: path("\(home)/Desktop"), home: home) == .desktop)
        #expect(
            SidebarLocations.standardKind(for: path("\(home)/Documents"), home: home) == .documents
        )
        #expect(
            SidebarLocations.standardKind(for: path("\(home)/Downloads"), home: home) == .downloads
        )
        #expect(
            SidebarLocations.standardKind(for: path("\(home)/Pictures"), home: home) == .pictures
        )
        #expect(SidebarLocations.standardKind(for: path("\(home)/Music"), home: home) == .music)
        #expect(SidebarLocations.standardKind(for: path("\(home)/Movies"), home: home) == .movies)
        #expect(
            SidebarLocations.standardKind(for: path("/Applications"), home: home) == .applications
        )
    }

    @Test("an ordinary folder has no standard kind")
    func standardKindRejectsOrdinaryFolders() {
        let home = "/Users/me"
        #expect(SidebarLocations.standardKind(for: path("/Users/me/Projects"), home: home) == nil)
        #expect(SidebarLocations.standardKind(for: path("/tmp"), home: home) == nil)
        // Right name, wrong depth — a nested "Documents" is not *the* Documents.
        #expect(
            SidebarLocations.standardKind(for: path("/Users/me/Work/Documents"), home: home) == nil
        )
        // Right name, different home.
        #expect(
            SidebarLocations.standardKind(for: path("/Users/other/Desktop"), home: home) == nil
        )
    }

    @Test("a remote path never classifies as a standard place")
    func standardKindIgnoresOtherBackends() {
        let home = "/Users/me"
        let remote = VFSPath(backend: VFSBackendID("sftp:example.com"), path: "\(home)/Desktop")
        #expect(SidebarLocations.standardKind(for: remote, home: home) == nil)
    }

    @Test("every kind favorites() enumerates is one standardKind can classify back")
    func classifierAgreesWithEnumeration() throws {
        // The two read one shared table; this is the regression test for them drifting apart.
        let temp = try TempTree()
        defer { temp.cleanup() }
        for folder in ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"] {
            try temp.makeDir(folder)
        }

        let favorites = SidebarLocations.favorites(home: temp.root.path)
        #expect(!favorites.isEmpty)
        for favorite in favorites {
            let classified = SidebarLocations.standardKind(
                for: favorite.path,
                home: temp.root.path
            )
            #expect(classified == favorite.kind, "\(favorite.name) did not classify back")
        }
    }
}
