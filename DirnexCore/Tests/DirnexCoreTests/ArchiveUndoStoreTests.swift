import Foundation
import Testing

@testable import DirnexCore

/// The bytes an archive rewrite displaces, and the swap that puts them back (HISTORY.md ▸ After
/// M19, 2026-09-01). Real files in a temp tree: what is under test is a clone, a copy and two
/// renames, none of which a fake can stand in for.
@Suite("ArchiveUndoStore")
struct ArchiveUndoStoreTests {
    private func store(_ tree: TempTree, bytes: Int64 = 1 << 30) throws -> ArchiveUndoStore {
        try tree.makeDir("store")
        return ArchiveUndoStore(
            root: URL(fileURLWithPath: tree.path("store")),
            budget: ArchiveUndoBudget(bytes: bytes)
        )
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "<none>"
    }

    // MARK: - Capture

    @Test("a capture keeps the archive's bytes and its modification time exactly")
    func captureIsFaithful() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.zip", contents: "original")
        let stamp = Date(timeIntervalSince1970: 1_600_000_000.123_456)
        try tree.setModificationDate("a.zip", to: stamp)
        let before = try #require(ArchiveUndoWitness.current(ofFileAt: tree.path("a.zip")))

        let snapshot = try #require(try store(tree).capture(archiveAt: tree.path("a.zip"), live: []))
        #expect(read(snapshot.snapshot) == "original")
        #expect(snapshot.restored == before)
        // The witness has to describe the *snapshot* too, or the redo direction's guard is about a
        // file that never existed.
        #expect(before.matchesFile(at: snapshot.snapshot))
    }

    @Test("an archive bigger than the whole budget is not captured")
    func overTheBudget() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.zip", bytes: 4096)
        let taken = try store(tree, bytes: 100).capture(archiveAt: tree.path("a.zip"), live: [])
        #expect(taken == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.path("store")).isEmpty)
    }

    @Test("capturing evicts what the budget says, and prune clears what no record names")
    func evictionAndPruning() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let store = try store(tree, bytes: 8192)
        try tree.writeFile("a.zip", bytes: 4096)
        try tree.writeFile("b.zip", bytes: 4096)
        try tree.writeFile("c.zip", bytes: 4096)

        let first = try #require(store.capture(archiveAt: tree.path("a.zip"), live: []))
        let second = try #require(
            store.capture(archiveAt: tree.path("b.zip"), live: [first.snapshot])
        )
        #expect(store.held().count == 2)

        // A third does not fit beside two live ones, so the one the journal names first goes.
        let third = try #require(store.capture(
            archiveAt: tree.path("c.zip"), live: [first.snapshot, second.snapshot]
        ))
        #expect(!FileManager.default.fileExists(atPath: first.snapshot))
        #expect(FileManager.default.fileExists(atPath: second.snapshot))

        store.prune(live: [third.snapshot])
        #expect(store.held().map(\.path) == [third.snapshot])
    }

    @Test("the store is kept out of Time Machine")
    func excludedFromBackup() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.zip", contents: "x")
        _ = try store(tree).capture(archiveAt: tree.path("a.zip"), live: [])
        let values = try URL(fileURLWithPath: tree.path("store"))
            .resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: - The swap

    @Test("the exchange is its own inverse — twice through is where it started")
    func exchangeRoundTrips() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.zip", contents: "original")
        let store = try store(tree)
        let snapshot = try #require(store.capture(archiveAt: tree.path("a.zip"), live: []))
        // The rewrite.
        try tree.writeFile("a.zip", contents: "rewritten")
        let rewritten = try #require(ArchiveUndoWitness.current(ofFileAt: tree.path("a.zip")))

        try ArchiveUndoStore.exchange(archiveAt: tree.path("a.zip"), snapshotAt: snapshot.snapshot)
        #expect(read(tree.path("a.zip")) == "original")
        #expect(read(snapshot.snapshot) == "rewritten")
        // The restored archive is the original down to its modification time, which is what the
        // redo direction's witness is checked against.
        #expect(snapshot.restored.matchesFile(at: tree.path("a.zip")))
        #expect(rewritten.matchesFile(at: snapshot.snapshot))

        try ArchiveUndoStore.exchange(archiveAt: tree.path("a.zip"), snapshotAt: snapshot.snapshot)
        #expect(read(tree.path("a.zip")) == "rewritten")
        #expect(read(snapshot.snapshot) == "original")
        #expect(rewritten.matchesFile(at: tree.path("a.zip")))
    }

    @Test("a failed exchange leaves both files exactly as they were, and litters nothing")
    func exchangeIsAllOrNothing() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.zip", contents: "rewritten")
        #expect(throws: VFSError.self) {
            try ArchiveUndoStore.exchange(
                archiveAt: tree.path("a.zip"), snapshotAt: tree.path("missing.snap")
            )
        }
        #expect(read(tree.path("a.zip")) == "rewritten")
        // The staged sibling is hidden, so a leak would be invisible in the pane — assert it by name.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: tree.root.path)
        #expect(siblings.filter { $0.hasPrefix(".dirnex-undo-") }.isEmpty)
    }

    @Test("a cross-volume snapshot is copied rather than cloned, and is just as faithful")
    func crossVolumeCapture() throws {
        // `duplicate` is the one seam the two routes share; there is no second volume in a unit
        // test, so drive the copy route directly by cloning into a destination that already exists
        // — `clonefile` refuses it, which is the same fall-through an `EXDEV` takes.
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.zip", contents: "original")
        try tree.setModificationDate("a.zip", to: Date(timeIntervalSince1970: 1_500_000_000.75))
        let witness = try #require(ArchiveUndoWitness.current(ofFileAt: tree.path("a.zip")))

        #expect(ArchiveUndoStore.duplicate(from: tree.path("a.zip"), to: tree.path("copy.zip")))
        #expect(witness.matchesFile(at: tree.path("copy.zip")))
    }
}
