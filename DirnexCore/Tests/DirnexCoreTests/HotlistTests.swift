import Foundation
import Testing

@testable import DirnexCore

@Suite("Hotlist")
struct HotlistTests {
    private func path(_ raw: String) -> VFSPath { .local(raw) }

    @Test("a fresh hotlist is empty")
    func startsEmpty() {
        #expect(Hotlist().entries.isEmpty)
    }

    @Test("add appends in order and derives the name from the folder")
    func addAppends() {
        var hotlist = Hotlist()
        let addedFirst = hotlist.add(HotlistEntry(path: path("/Users/me/Downloads")))
        let addedSecond = hotlist.add(HotlistEntry(path: path("/Users/me/Projects")))
        #expect(addedFirst)
        #expect(addedSecond)
        #expect(hotlist.entries.map(\.name) == ["Downloads", "Projects"])
        #expect(
            hotlist.entries.map(\.path) == [path("/Users/me/Downloads"), path("/Users/me/Projects")]
        )
    }

    @Test("add de-duplicates by path without reordering or renaming the existing entry")
    func addDeduplicates() {
        var hotlist = Hotlist()
        hotlist.add(HotlistEntry(name: "Work", path: path("/Users/me/Projects")))
        hotlist.add(HotlistEntry(path: path("/Users/me/Downloads")))

        let addedDuplicate = hotlist.add(
            HotlistEntry(name: "Renamed", path: path("/Users/me/Projects"))
        )
        #expect(!addedDuplicate)
        #expect(hotlist.entries.count == 2)
        // The original name and its leading position are preserved.
        #expect(hotlist.entries.first?.name == "Work")
    }

    @Test("contains reflects what is pinned")
    func containsReflectsPins() {
        var hotlist = Hotlist()
        hotlist.add(HotlistEntry(path: path("/tmp/a")))
        #expect(hotlist.contains(path("/tmp/a")))
        #expect(!hotlist.contains(path("/tmp/b")))
    }

    @Test("remove(path:) unpins and reports whether anything was removed")
    func removeByPath() {
        var hotlist = Hotlist()
        hotlist.add(HotlistEntry(path: path("/tmp/a")))
        hotlist.add(HotlistEntry(path: path("/tmp/b")))

        let removedExisting = hotlist.remove(path: path("/tmp/a"))
        #expect(removedExisting)
        #expect(hotlist.entries.map(\.path) == [path("/tmp/b")])
        let removedMissing = hotlist.remove(path: path("/tmp/missing"))
        #expect(!removedMissing)
    }

    @Test("remove(at:) drops the indexed entry and ignores out-of-range")
    func removeByIndex() {
        var hotlist = Hotlist(entries: [
            HotlistEntry(path: path("/a")), HotlistEntry(path: path("/b")),
            HotlistEntry(path: path("/c"))
        ])
        hotlist.remove(at: 1)
        #expect(hotlist.entries.map(\.path) == [path("/a"), path("/c")])
        hotlist.remove(at: 9) // no crash, no change
        #expect(hotlist.entries.count == 2)
    }

    @Test("rename changes only the matching entry's label")
    func renameEntry() {
        var hotlist = Hotlist(entries: [
            HotlistEntry(path: path("/Users/me/Downloads")),
            HotlistEntry(path: path("/Users/me/Projects"))
        ])
        hotlist.rename(path: path("/Users/me/Projects"), to: "Work")
        #expect(hotlist.entries.map(\.name) == ["Downloads", "Work"])
    }

    @Test("move reorders using resulting-array semantics")
    func moveReorders() {
        func fresh() -> Hotlist {
            Hotlist(entries: [
                HotlistEntry(name: "A", path: path("/a")),
                HotlistEntry(name: "B", path: path("/b")),
                HotlistEntry(name: "C", path: path("/c"))
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
        let original = Hotlist(entries: [
            HotlistEntry(name: "Work", path: path("/Users/me/Projects")),
            HotlistEntry(path: path("/Users/me/Downloads"))
        ])
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Hotlist.self, from: data)
        #expect(restored == original)
    }

    @Test("initializer and decoding both collapse duplicate paths")
    func duplicatesCollapseOnLoad() throws {
        let withDupes = [
            HotlistEntry(name: "First", path: path("/dup")),
            HotlistEntry(name: "Second", path: path("/dup")),
            HotlistEntry(path: path("/other"))
        ]
        let hotlist = Hotlist(entries: withDupes)
        #expect(hotlist.entries.map(\.name) == ["First", "other"])

        // A store that somehow serialized duplicates is sanitized when decoded.
        let json = try JSONEncoder().encode(["entries": withDupes])
        let decoded = try JSONDecoder().decode(Hotlist.self, from: json)
        #expect(decoded.entries.map(\.path) == [path("/dup"), path("/other")])
    }
}
