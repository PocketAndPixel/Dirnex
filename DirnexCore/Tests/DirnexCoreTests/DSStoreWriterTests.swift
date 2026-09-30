import Foundation
import Testing

@testable import DirnexCore

/// The `.DS_Store` writer (PLAN.md §M26 Slice 5).
///
/// The oracle throughout is **macOS's own bytes**: the fixture is a real `.DS_Store` written by
/// `FileManager.trashItem` on a scratch volume, and the strongest claim here is that it survives a
/// trip through this writer unchanged. What no test can answer is whether *Finder* accepts the
/// result — that was measured live 2026-08-31 against `~/.Trash` and Google Drive's
/// `<mount>/.Trash`, where the pair written by this code made Put Back appear in an already-open
/// context menu and restored the file to the right folder, and where Finder then rewrote the file
/// from our content with all 284 of its own records intact.
@Suite("DS_Store writer")
struct DSStoreWriterTests {
    private func fixture() throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: "volume-trash",
                withExtension: "dsstore",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Round trip

    @Test("a real macOS-written database survives a rewrite unchanged")
    func roundTripsARealStore() throws {
        let original = try DSStoreReader.entries(in: fixture())
        let rewritten = try #require(DSStoreWriter.data(for: original))

        #expect(try DSStoreReader.entries(in: rewritten) == original)
    }

    /// The property the *whole* rewrite rests on: a trash's database is Finder's, and a record this
    /// build has no opinion about has to come back byte for byte. Nothing in a trash carries these
    /// types today — which is exactly why they are asserted rather than assumed, since the day one
    /// appears is the day a rewrite would silently drop it.
    @Test("record types this build does not interpret come back byte for byte")
    func preservesForeignRecords() throws {
        let entries = [
            DSStoreEntry(
                filename: "a.txt",
                key: "Iloc",
                type: "blob",
                encodedValue: [0, 0, 0, 3, 9, 8, 7]
            ),
            DSStoreEntry(filename: "b.txt", key: "moDD", type: "dutc", encodedValue: Array(1...8)),
            DSStoreEntry(filename: "c.txt", key: "fwvh", type: "shor", encodedValue: [0, 0, 1, 44]),
            DSStoreEntry(filename: "d.txt", key: "ph1S", type: "bool", encodedValue: [1]),
            DSStoreEntry.string(filename: "e.txt", key: "ptbN", value: "e.txt")
        ]

        let data = try #require(DSStoreWriter.data(for: entries))

        #expect(try DSStoreReader.entries(in: data) == entries)
    }

    @Test("a written database still reads as put-back records")
    func readsBackAsPutBack() throws {
        let trash = VFSPath.local("/Volumes/DirnexProbe/.Trashes/501")
        let entries = try DSStoreReader.entries(in: fixture())
        let data = try #require(DSStoreWriter.data(for: entries))

        let origins = try TrashPutBack.origins(inDSStore: data, ofTrashAt: trash)

        #expect(origins["beta file.txt"]?.directory == .local("/Volumes/DirnexProbe/deep/nested"))
        #expect(origins["alpha.txt 13-12-35-977.txt"]?.name == "alpha.txt")
    }

    // MARK: - The tree

    /// One page holds a few dozen records, so a real trash is already several nodes deep — the
    /// fixture's four cannot reach an internal node at all, and a writer that only ever produced a
    /// single leaf would pass every test above.
    @Test("a database too large for one page reads back whole, and in order")
    func buildsAMultiLevelTree() throws {
        let entries = (0..<4000).map {
            DSStoreEntry.string(
                filename: String(format: "item-%05d.txt", $0),
                key: "ptbL",
                value: "Users/oleg/Documents/some/reasonably/long/folder/name/\($0)/"
            )
        }

        let data = try #require(DSStoreWriter.data(for: entries))
        let read = try DSStoreReader.entries(in: data)

        #expect(read == entries)
        #expect(read.map(\.filename) == entries.map(\.filename))
    }

    @Test("records are written in the format's own order, whatever order they arrive in")
    func sortsRecords() throws {
        let entries = [
            DSStoreEntry.string(filename: "Zebra.txt", key: "ptbN", value: "z"),
            DSStoreEntry.string(filename: "Zebra.txt", key: "ptbL", value: "l"),
            DSStoreEntry.string(filename: "apple.txt", key: "ptbL", value: "l")
        ]

        let data = try #require(DSStoreWriter.data(for: entries))
        let read = try DSStoreReader.entries(in: data)

        #expect(
            read.map { "\($0.filename)/\($0.key)" } == [
                "apple.txt/ptbL",
                "Zebra.txt/ptbL",
                "Zebra.txt/ptbN"
            ]
        )
    }

    /// Validated against the 284 records in this Mac's own `~/.Trash/.DS_Store`, which Finder and
    /// `trashItem` wrote over months and which have zero inversions under this comparator.
    @Test("the order is case-insensitive by name, then by property id")
    func ordersCaseInsensitively() {
        let amplitude = DSStoreEntry.string(filename: "amplitude", key: "ptbL", value: "")
        let assistant = DSStoreEntry.string(filename: "Assistant", key: "ptbL", value: "")
        let location = DSStoreEntry.string(filename: "same", key: "ptbL", value: "")
        let name = DSStoreEntry.string(filename: "same", key: "ptbN", value: "")

        #expect(DSStoreEntry.isOrderedBefore(amplitude, assistant))
        #expect(!DSStoreEntry.isOrderedBefore(assistant, amplitude))
        #expect(DSStoreEntry.isOrderedBefore(location, name))
    }

    // MARK: - Values

    @Test("a string value round-trips through its own encoding, non-ASCII included")
    func encodesStrings() {
        let entry = DSStoreEntry.string(filename: "n", key: "ptbL", value: "Users/oleg/Документы/")

        #expect(entry.stringValue == "Users/oleg/Документы/")
        #expect(entry.type == "ustr")
    }

    @Test("a non-string record has no string value")
    func nonStringsHaveNoText() {
        let entry = DSStoreEntry(
            filename: "n",
            key: "Iloc",
            type: "blob",
            encodedValue: [0, 0, 0, 1, 7]
        )

        #expect(entry.stringValue == nil)
    }
}
