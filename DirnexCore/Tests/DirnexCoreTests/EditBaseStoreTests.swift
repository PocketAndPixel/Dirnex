import Foundation
import Testing

@testable import DirnexCore

/// The bases kept for edited copies of server files (PLAN.md §M34 Slice 4). Real files in a temp
/// tree: what is under test is a clone and a removal, which a fake cannot stand in for.
@Suite("EditBaseStore")
struct EditBaseStoreTests {
    private func store(_ tree: TempTree) throws -> EditBaseStore {
        try tree.makeDir("bases")
        return EditBaseStore(root: URL(fileURLWithPath: tree.path("bases")))
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? "<none>"
    }

    @Test("a kept base holds the copy's bytes, time and name, in a folder of its own")
    func keepIsFaithful() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("copy")
        try tree.writeFile("copy/notes.txt", contents: "as downloaded")
        try tree.setModificationDate(
            "copy/notes.txt",
            to: Date(timeIntervalSince1970: 1_600_000_000.123_456)
        )
        let store = try store(tree)
        let copy = URL(fileURLWithPath: tree.path("copy/notes.txt"))

        let kept = try #require(store.keep(copy))
        #expect(read(kept) == "as downloaded")
        #expect(kept.lastPathComponent == "notes.txt")
        #expect(kept.deletingLastPathComponent().deletingLastPathComponent().path == store.root.path)
        #expect(EditedFileRevision.current(ofFileAt: kept.path)
            == EditedFileRevision.current(ofFileAt: copy.path))

        // The editor's save then leaves the base as it was.
        try tree.writeFile("copy/notes.txt", contents: "edited")
        #expect(read(kept) == "as downloaded")
    }

    @Test("two bases of one copy land in two folders")
    func twoBasesDoNotCollide() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("notes.txt", contents: "first")
        let store = try store(tree)
        let copy = URL(fileURLWithPath: tree.path("notes.txt"))

        let first = try #require(store.keep(copy))
        try tree.writeFile("notes.txt", contents: "second")
        let second = try #require(store.keep(copy))
        #expect(first != second)
        #expect(read(first) == "first")
        #expect(read(second) == "second")
    }

    @Test("a copy that is not there keeps nothing and leaves nothing")
    func missingCopy() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let store = try store(tree)
        #expect(store.keep(URL(fileURLWithPath: tree.path("gone.txt"))) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    }

    @Test("discarding a base removes it with its folder, and refuses a file anywhere else")
    func discard() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("notes.txt", contents: "mine")
        let store = try store(tree)
        let copy = URL(fileURLWithPath: tree.path("notes.txt"))
        let kept = try #require(store.keep(copy))

        store.discard(kept)
        #expect(!FileManager.default.fileExists(atPath: kept.deletingLastPathComponent().path))
        // The user's file is not in a folder of the store's, so it stays, and so does its folder.
        store.discard(copy)
        #expect(read(copy) == "mine")
        // Nor is the store's root itself one of its folders.
        store.discard(store.root.appendingPathComponent("stray.txt"))
        #expect(FileManager.default.fileExists(atPath: store.root.path))
    }
}
