import Foundation
import Testing

@testable import DirnexCore

@Suite("Favorites")
struct FavoritesTests {
    private func path(_ raw: String) -> VFSPath { .local(raw) }

    @Test("a fresh favorites is empty")
    func startsEmpty() {
        #expect(Favorites().entries.isEmpty)
    }

    @Test("add appends in order and derives the name from the folder")
    func addAppends() {
        var favorites = Favorites()
        let addedFirst = favorites.add(FavoriteEntry(path: path("/Users/me/Downloads")))
        let addedSecond = favorites.add(FavoriteEntry(path: path("/Users/me/Projects")))
        #expect(addedFirst)
        #expect(addedSecond)
        #expect(favorites.entries.map(\.name) == ["Downloads", "Projects"])
        #expect(
            favorites.entries.map(\.path) == [
                path("/Users/me/Downloads"),
                path("/Users/me/Projects")
            ]
        )
    }

    @Test("add de-duplicates by path without reordering or renaming the existing entry")
    func addDeduplicates() {
        var favorites = Favorites()
        favorites.add(FavoriteEntry(name: "Work", path: path("/Users/me/Projects")))
        favorites.add(FavoriteEntry(path: path("/Users/me/Downloads")))

        let addedDuplicate = favorites.add(
            FavoriteEntry(name: "Renamed", path: path("/Users/me/Projects"))
        )
        #expect(!addedDuplicate)
        #expect(favorites.entries.count == 2)
        // The original name and its leading position are preserved.
        #expect(favorites.entries.first?.name == "Work")
    }

    @Test("contains reflects what is pinned")
    func containsReflectsPins() {
        var favorites = Favorites()
        favorites.add(FavoriteEntry(path: path("/tmp/a")))
        #expect(favorites.contains(path("/tmp/a")))
        #expect(!favorites.contains(path("/tmp/b")))
    }

    @Test("remove(path:) unpins and reports whether anything was removed")
    func removeByPath() {
        var favorites = Favorites()
        favorites.add(FavoriteEntry(path: path("/tmp/a")))
        favorites.add(FavoriteEntry(path: path("/tmp/b")))

        let removedExisting = favorites.remove(path: path("/tmp/a"))
        #expect(removedExisting)
        #expect(favorites.entries.map(\.path) == [path("/tmp/b")])
        let removedMissing = favorites.remove(path: path("/tmp/missing"))
        #expect(!removedMissing)
    }

    @Test("remove(at:) drops the indexed entry and ignores out-of-range")
    func removeByIndex() {
        var favorites = Favorites(entries: [
            FavoriteEntry(path: path("/a")), FavoriteEntry(path: path("/b")),
            FavoriteEntry(path: path("/c"))
        ])
        favorites.remove(at: 1)
        #expect(favorites.entries.map(\.path) == [path("/a"), path("/c")])
        favorites.remove(at: 9) // no crash, no change
        #expect(favorites.entries.count == 2)
    }

    @Test("rename changes only the matching entry's label")
    func renameEntry() {
        var favorites = Favorites(entries: [
            FavoriteEntry(path: path("/Users/me/Downloads")),
            FavoriteEntry(path: path("/Users/me/Projects"))
        ])
        favorites.rename(path: path("/Users/me/Projects"), to: "Work")
        #expect(favorites.entries.map(\.name) == ["Downloads", "Work"])
    }

    @Test("move reorders using resulting-array semantics")
    func moveReorders() {
        func fresh() -> Favorites {
            Favorites(entries: [
                FavoriteEntry(name: "A", path: path("/a")),
                FavoriteEntry(name: "B", path: path("/b")),
                FavoriteEntry(name: "C", path: path("/c"))
            ])
        }

        var toEnd = fresh()
        toEnd.move(from: 0, to: 2)
        #expect(toEnd.entries.map(\.name) == ["B", "C", "A"])

        var toStart = fresh()
        toStart.move(from: 2, to: 0)
        #expect(toStart.entries.map(\.name) == ["C", "A", "B"])

        var middle = fresh()
        middle.move(from: 0, to: 1)
        #expect(middle.entries.map(\.name) == ["B", "A", "C"])

        var outOfRange = fresh()
        outOfRange.move(from: 5, to: 0) // ignored
        #expect(outOfRange.entries.map(\.name) == ["A", "B", "C"])
    }

    @Test("Codable round-trips the entries in order")
    func codableRoundTrips() throws {
        let original = Favorites(entries: [
            FavoriteEntry(name: "Work", path: path("/Users/me/Projects")),
            FavoriteEntry(path: path("/Users/me/Downloads"))
        ])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Favorites.self, from: data)
        #expect(restored == original)
    }

    @Test("initializer and decoding both collapse duplicate paths")
    func duplicatesCollapseOnLoad() throws {
        let withDupes = [
            FavoriteEntry(name: "First", path: path("/dup")),
            FavoriteEntry(name: "Second", path: path("/dup")),
            FavoriteEntry(path: path("/other"))
        ]
        let favorites = Favorites(entries: withDupes)
        #expect(favorites.entries.map(\.name) == ["First", "other"])

        // A store that somehow serialized duplicates is sanitized when decoded.
        let json = try JSONEncoder().encode(["entries": withDupes])
        let decoded = try JSONDecoder().decode(Favorites.self, from: json)
        #expect(decoded.entries.map(\.path) == [path("/dup"), path("/other")])
    }
}
