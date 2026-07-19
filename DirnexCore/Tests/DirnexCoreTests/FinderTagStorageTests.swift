import Foundation
import Testing

@testable import DirnexCore

/// These run against real files in a throwaway tree, like the `LocalBackend` and `ByteComparator`
/// suites: the whole point of the type is what macOS does with the attribute, and a fake would
/// only re-assert this pass's own assumptions back at it.
@Suite("FinderTagStorage")
struct FinderTagStorageTests {
    /// Input this code did not spell, so the read path is tested against macOS's own bytes rather
    /// than against `FinderTagPayload.encode`'s.
    ///
    /// It writes the attribute directly because `URLResourceValues.tagNames`' **setter is macOS 26+**
    /// and this package targets 14 — see `FinderTagStorage` on why that settles the write path. The
    /// strings below are the exact spellings the system produced for these names when probed, so
    /// this stands in for it faithfully; the getter, which *is* available, is what the assertions
    /// then read back through.
    private func tagAsSystemWould(_ path: String, _ stored: [String]) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: stored,
            format: .binary,
            options: 0
        )
        let result = data.withUnsafeBytes {
            setxattr(path, FinderTagStorage.tagsAttribute, $0.baseAddress, data.count, 0, 0)
        }
        #expect(result == 0)
    }

    private func rawStrings(_ path: String) -> [String] {
        let size = getxattr(path, FinderTagStorage.tagsAttribute, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        _ = data.withUnsafeMutableBytes { getxattr(
            path,
            FinderTagStorage.tagsAttribute,
            $0.baseAddress,
            size,
            0,
            0
        ) }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String] ?? [
        ]
    }

    private func legacyLabel(_ path: String) -> Int? {
        let size = getxattr(path, FinderTagStorage.finderInfoAttribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        _ = getxattr(path, FinderTagStorage.finderInfoAttribute, &bytes, size, 0, 0)
        return Int((bytes[9] >> 1) & 7)
    }

    // MARK: - Reading

    @Test("an untagged file has no tags, and that is not an error")
    func untaggedFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("plain.txt", contents: "x")
        #expect(try FinderTagStorage.tags(at: tree.vfsPath("plain.txt")).isEmpty)
    }

    /// The crux of the read path: colours, which the documented `tagNamesKey` reader drops entirely
    /// (it answers `["Red"]` for a file the system stored as `Red\n6`). A column that cannot show a
    /// colour is the whole reason this reads the attribute by hand.
    @Test("reads names and colours the system wrote")
    func readsSystemWrittenTags() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try tree.writeFile("tagged.txt", contents: "x")
        try tagAsSystemWould(file, ["Red\n6", "Blue\n4", "Zebra\n0"])

        let tags = try FinderTagStorage.tags(at: tree.vfsPath("tagged.txt"))
        #expect(tags.map(\.name) == ["Red", "Blue", "Zebra"])
        #expect(tags.map(\.color) == [.red, .blue, FinderTagColor.none])

        // For contrast, the reader the obvious implementation would have used. It agrees on the
        // names and cannot express a colour at all — which is what rules it out for the column.
        let viaResourceValues = try URL(fileURLWithPath: file).resourceValues(
            forKeys: [.tagNamesKey]
        ).tagNames
        #expect(viaResourceValues == ["Red", "Blue", "Zebra"])
    }

    @Test("directories carry tags too")
    func readsDirectoryTags() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let dir = try tree.makeDir("folder")
        try tagAsSystemWould(dir, ["Green\n2"])
        #expect(try FinderTagStorage.tags(at: tree.vfsPath("folder")) == [FinderTag(name: "Green")])
    }

    @Test("a missing file is notFound, not an empty tag list")
    func missingFileThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        #expect(throws: VFSError.notFound(tree.vfsPath("ghost.txt"))) {
            try FinderTagStorage.tags(at: tree.vfsPath("ghost.txt"))
        }
    }

    /// A remote or in-archive file has no extended attributes to read. Answering `[]` would state
    /// that it definitely has no tags, which is a different and unearned claim.
    @Test("a non-local path is unsupported rather than untagged")
    func nonLocalUnsupported() {
        let archive = VFSPath(backend: .archive(forArchiveAt: "/tmp/a.zip"), path: "/inner.txt")
        #expect(throws: VFSError.self) { try FinderTagStorage.tags(at: archive) }
        #expect(throws: VFSError.self) { try FinderTagStorage.setTags(
            [FinderTag(name: "Red")],
            at: archive
        ) }
    }

    // MARK: - Writing

    @Test("tags we write are the tags the system reads back")
    func writeIsReadableBySystem() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try tree.writeFile("w.txt", contents: "x")

        try FinderTagStorage.setTags(
            [FinderTag(name: "Red", color: .red), FinderTag(name: "Zebra", color: .purple)],
            at: tree.vfsPath("w.txt")
        )

        #expect(rawStrings(file) == ["Red\n6", "Zebra\n3"])
        let viaResourceValues = try URL(fileURLWithPath: file).resourceValues(
            forKeys: [.tagNamesKey]
        ).tagNames
        #expect(viaResourceValues == ["Red", "Zebra"])
    }

    /// The reason this type writes the attribute by hand. `URLResourceValues.tagNames` takes bare
    /// names and looks each colour up in a global database that a write of ours never registers
    /// into, so expressing an edit through it strips the colour off every custom tag — probed:
    /// after storing a purple `Zebra`, setting `tagNames = ["Zebra"]` writes `Zebra\n0`.
    ///
    /// The failure cannot be asserted here, because that setter is macOS 26+ and this package
    /// targets 14 — it would not compile. What *is* asserted is the property that matters: an edit
    /// preserves the colour of a tag the system itself has no colour for.
    @Test("a custom tag's colour survives an unrelated edit")
    func customColorSurvivesRewrite() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try tree.writeFile("ours.txt", contents: "x")
        let path = tree.vfsPath("ours.txt")
        let purpleZebra = FinderTag(name: "Zebra", color: .purple)

        // Read the tags, add one, write them back — the shape of every edit from the panel.
        try FinderTagStorage.setTags([purpleZebra], at: path)
        try FinderTagStorage.add(FinderTag(name: "Red", color: .red), to: path)

        #expect(try FinderTagStorage.tags(at: path) == [purpleZebra, FinderTag(name: "Red")])
        #expect(try FinderTagStorage.tags(at: path).first?.color == .purple)
        #expect(rawStrings(file) == ["Zebra\n3", "Red\n6"])
    }

    @Test("adding a tag the file already carries changes nothing")
    func addIsIdempotent() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "x")
        let path = tree.vfsPath("a.txt")

        try FinderTagStorage.add(FinderTag(name: "Work", color: .blue), to: path)
        // The same tag, in a different spelling and colour.
        try FinderTagStorage.add(FinderTag(name: "work", color: .red), to: path)
        #expect(try FinderTagStorage.tags(at: path) == [FinderTag(name: "Work")])
        #expect(try FinderTagStorage.tags(at: path).first?.color == .blue) // the first write's colour stands
    }

    @Test("removing a tag leaves the others, removing an absent one is a no-op")
    func removeTag() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("r.txt", contents: "x")
        let path = tree.vfsPath("r.txt")
        try FinderTagStorage.setTags(
            [FinderTag(name: "Red", color: .red), FinderTag(name: "Blue", color: .blue)],
            at: path
        )

        try FinderTagStorage.remove(FinderTag(name: "red"), from: path) // case-insensitive, as macOS identifies tags
        #expect(try FinderTagStorage.tags(at: path) == [FinderTag(name: "Blue")])

        try FinderTagStorage.remove(FinderTag(name: "Never"), from: path)
        #expect(try FinderTagStorage.tags(at: path) == [FinderTag(name: "Blue")])
    }

    /// Clearing tags should leave the file indistinguishable from one that never had any — an
    /// empty array stored in the attribute is a state the system does not produce.
    @Test("clearing tags removes the attribute outright")
    func clearingRemovesAttribute() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try tree.writeFile("c.txt", contents: "x")
        let path = tree.vfsPath("c.txt")

        try FinderTagStorage.setTags([FinderTag(name: "Red", color: .red)], at: path)
        try FinderTagStorage.setTags([], at: path)

        #expect(try FinderTagStorage.tags(at: path).isEmpty)
        #expect(getxattr(file, FinderTagStorage.tagsAttribute, nil, 0, 0, 0) == -1)
        #expect(errno == ENOATTR)
    }

    // MARK: - The legacy label

    /// The system keeps this byte in step with the tag list; a plain attribute write does not, and
    /// leaves the file saying "tagged Red, label none" — a state macOS itself never produces.
    @Test("writing tags maintains the legacy label byte")
    func maintainsLegacyLabel() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try tree.writeFile("l.txt", contents: "x")
        let path = tree.vfsPath("l.txt")

        try FinderTagStorage.setTags([FinderTag(name: "Red", color: .red)], at: path)
        #expect(legacyLabel(file) == 6)

        // Last coloured tag wins — the rule read off the system's own writes.
        try FinderTagStorage.setTags(
            [FinderTag(name: "Red", color: .red), FinderTag(name: "Orange", color: .orange)],
            at: path
        )
        #expect(legacyLabel(file) == 7)
    }

    /// Matches the system: a file tagged only `Work` has no FinderInfo record at all.
    @Test("a colourless tag does not conjure a FinderInfo record")
    func colorlessTagLeavesNoRecord() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try tree.writeFile("n.txt", contents: "x")
        try FinderTagStorage.setTags([FinderTag(name: "Work")], at: tree.vfsPath("n.txt"))
        #expect(legacyLabel(file) == nil)
    }

    /// FinderInfo's other 31 bytes are type/creator codes and flags belonging to whoever wrote
    /// them; setting a colour must not zero them.
    @Test("the rest of the FinderInfo record survives a label change")
    func preservesOtherFinderInfoBytes() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try tree.writeFile("fi.txt", contents: "x")

        var record = [UInt8](repeating: 0, count: 32)
        record[0..<4] = [0x54, 0x45, 0x58, 0x54][0...] // 'TEXT' file type
        record[4..<8] = [0x74, 0x74, 0x78, 0x74][0...] // 'ttxt' creator
        record[9] = 0b1000_0000 // an unrelated flag bit sharing the label's byte
        _ = record.withUnsafeBytes { setxattr(
            file,
            FinderTagStorage.finderInfoAttribute,
            $0.baseAddress,
            32,
            0,
            0
        ) }

        try FinderTagStorage.setTags(
            [FinderTag(name: "Blue", color: .blue)],
            at: tree.vfsPath("fi.txt")
        )

        var after = [UInt8](repeating: 0, count: 32)
        _ = getxattr(file, FinderTagStorage.finderInfoAttribute, &after, 32, 0, 0)
        #expect(Array(after[0..<8]) == [0x54, 0x45, 0x58, 0x54, 0x74, 0x74, 0x78, 0x74])
        #expect(after[9] & 0b1000_0000 == 0b1000_0000) // the neighbouring bit is untouched
        #expect((after[9] >> 1) & 7 == 4) // and the label is Blue
    }

    // MARK: - Names

    /// A tag name is user text: spaces, emoji, and decomposed accents all have to survive a
    /// round-trip through the attribute, since a name is the tag's identity.
    @Test("awkward names round-trip")
    func awkwardNames() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("u.txt", contents: "x")
        let path = tree.vfsPath("u.txt")
        let names = ["a space", "café", "🚀 ship it", "under_score"]

        try FinderTagStorage.setTags(names.map { FinderTag(name: $0, color: .green) }, at: path)
        #expect(try FinderTagStorage.tags(at: path).map(\.name) == names)
    }
}
