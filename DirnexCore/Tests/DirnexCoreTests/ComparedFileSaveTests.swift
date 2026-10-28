import Foundation
import Testing

@testable import DirnexCore

/// Saving a side of a comparison to its local file (PLAN.md §M33 Slice 3): what the save keeps, and
/// the three ways it refuses without touching the file.
@Suite("ComparedFileSave")
struct ComparedFileSaveTests {
    private typealias Fixture = SavedFileFixture

    private static let text = "one\ntwo\nthree\n"

    /// Save `document` over the file at `path` as read just now, with no undo store.
    @discardableResult
    private static func save(
        _ document: ComparedDocument,
        to path: String,
        writer: @escaping InPlaceFileWrite.Writer = InPlaceFileWrite.writeAll
    ) throws(ComparedFileSave.Failure) -> ComparedFileSave.Saved {
        try ComparedFileSave.save(
            document,
            to: .reading(path),
            overwritingChanges: false,
            undo: nil,
            writer: writer
        )
    }

    // MARK: - What a save keeps

    @Test("a save writes the lines and keeps the file and everything stored on it")
    func keepsTheFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("plain.txt", contents: Self.text)
        try Fixture.dress(path)
        let before = try Fixture.look(path)

        let saved = try Self.save(try Fixture.edited(Self.text, lastLine: "x"), to: path)

        #expect(Fixture.read(path) == "one\ntwo\nx\n")
        #expect(try Fixture.look(path) == before)
        #expect(saved.target == .reading(path))
        #expect(saved.undo == nil)
    }

    @Test("a save through a symlink writes its target and leaves the link a link")
    func writesThroughASymlink() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let target = try tree.writeFile("target.txt", contents: Self.text)
        try tree.symlink("link.txt", to: "target.txt")
        try Fixture.dress(target)
        let before = try Fixture.look(target)

        try Self.save(try Fixture.edited(Self.text, lastLine: "x"), to: tree.path("link.txt"))

        #expect(Fixture.read(target) == "one\ntwo\nx\n")
        #expect(try Fixture.look(target) == before)
        let link = try FileManager.default.attributesOfItem(atPath: tree.path("link.txt"))
        #expect(link[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: tree.path("link.txt"))
                == "target.txt"
        )
    }

    @Test("a save through one hard link shows under the other, which still names the same file")
    func keepsAHardLink() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("hard.txt", contents: Self.text)
        try FileManager.default.linkItem(atPath: path, toPath: tree.path("hard2.txt"))

        try Self.save(try Fixture.edited(Self.text, lastLine: "x"), to: path)

        #expect(Fixture.read(tree.path("hard2.txt")) == "one\ntwo\nx\n")
        #expect(try Fixture.look(path).links == 2)
        #expect(try Fixture.look(path).inode == Fixture.look(tree.path("hard2.txt")).inode)
    }

    @Test("a file whose ACL denies delete is saved, as a replacing save could not")
    func savesThroughAnACLThatDeniesDelete() throws {
        let tree = try TempTree()
        defer {
            Fixture.clearAccessControl(under: tree.root.path)
            tree.cleanup()
        }
        let path = try tree.writeFile("denied.txt", contents: Self.text)
        try Fixture.dress(path, acl: "everyone deny delete")

        try Self.save(try Fixture.edited(Self.text, lastLine: "x"), to: path)

        #expect(Fixture.read(path) == "one\ntwo\nx\n")
    }

    @Test("a saved document is unedited, until an edit made during the save or an undo past it")
    func markingSavedResetsEdited() throws {
        var document = try Fixture.edited(Self.text, lastLine: "x")
        let saving = document
        let inverse = document.apply(LineEdit(
            range: 0..<1,
            replacement: [TextLine(content: "zero", terminator: .lf)]
        ))
        document.markSaved(saving.lines)
        #expect(document.isEdited)
        document.apply(inverse)
        #expect(!document.isEdited)
        document.apply(
            LineEdit(range: 2..<3, replacement: [TextLine(content: "three", terminator: .lf)])
        )
        #expect(document.isEdited)
    }

    // MARK: - Refusals that touch nothing

    @Test("a file changed since it was read is refused, and saved when the user says so")
    func refusesAFileChangedSinceRead() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let read = ComparedFileSave.Target.reading(path)
        try tree.writeFile("a.txt", contents: "somebody else's\n")
        let document = try Fixture.edited(Self.text, lastLine: "x")

        #expect(throws: ComparedFileSave.Failure.changedSinceRead) {
            try ComparedFileSave.save(document, to: read, undo: nil)
        }
        #expect(Fixture.read(path) == "somebody else's\n")

        try ComparedFileSave.save(document, to: read, overwritingChanges: true, undo: nil)
        #expect(Fixture.read(path) == "one\ntwo\nx\n")
    }

    @Test("a file touched since it was read counts as changed, since only its time moved")
    func refusesAFileTouchedSinceRead() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let read = ComparedFileSave.Target.reading(path)
        try tree.setModificationDate("a.txt", to: Date(timeIntervalSinceNow: -3600))

        #expect(throws: ComparedFileSave.Failure.changedSinceRead) {
            try ComparedFileSave.save(
                try Fixture.edited(Self.text, lastLine: "x"),
                to: read,
                undo: nil
            )
        }
        #expect(Fixture.read(path) == Self.text)
    }

    @Test(
        "a character the encoding cannot hold is refused with its line, before anything is touched"
    )
    func refusesAnUnencodableCharacter() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let latin = try #require("café\nnaïve\n".data(using: .isoLatin1))
        let path = tree.path("latin.txt")
        try latin.write(to: URL(fileURLWithPath: path))
        var document = try ComparedDocument.read(contentsOf: URL(fileURLWithPath: path))
        #expect(document.encoding != .utf8)
        #expect(document.isSavable)
        document.apply(LineEdit(
            range: 1..<2,
            replacement: [TextLine(content: "a → b", terminator: .lf)]
        ))

        #expect(throws: ComparedFileSave.Failure.unencodable(line: 1, character: "→")) {
            try Self.save(document, to: path)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == latin)
    }

    @Test("a file that is gone is refused rather than created")
    func refusesAMissingFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        let read = ComparedFileSave.Target.reading(path)
        try FileManager.default.removeItem(atPath: path)

        #expect(throws: ComparedFileSave.Failure.failed(.notFound(.local(path)))) {
            try ComparedFileSave.save(
                try Fixture.edited(Self.text, lastLine: "x"),
                to: read,
                overwritingChanges: true,
                undo: nil
            )
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("a file this user may not write is refused with the file as it was")
    func refusesAReadOnlyFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let path = try tree.writeFile("a.txt", contents: Self.text)
        #expect(chmod(path, 0o444) == 0)

        #expect(throws: ComparedFileSave.Failure.failed(.permissionDenied(.local(path)))) {
            try Self.save(try Fixture.edited(Self.text, lastLine: "x"), to: path)
        }
        #expect(Fixture.read(path) == Self.text)
    }

    // MARK: - A write that fails partway

    @Test("a disk that fills partway through gets the old bytes and time back, and no undo copy")
    func putsTheOldBytesBackAfterAFailedWrite() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("store")
        let path = try tree.writeFile("a.txt", contents: Self.text)
        try tree.setModificationDate("a.txt", to: Date(timeIntervalSince1970: 1_700_000_000.25))
        let before = try #require(Fixture.modificationTime(path))
        let store = ArchiveUndoStore(root: URL(fileURLWithPath: tree.path("store")))
        // Half the bytes land, then the volume is full: the file is left torn unless the save
        // puts it back.
        let fillsUp: InPlaceFileWrite.Writer = { descriptor, data in
            _ = InPlaceFileWrite.writeAll(descriptor, data.prefix(data.count / 2))
            return ENOSPC
        }

        #expect(throws: ComparedFileSave.Failure.failed(.io(path: .local(path), code: ENOSPC))) {
            try ComparedFileSave.save(
                try Fixture.edited(Self.text, lastLine: "something much longer than three"),
                to: .reading(path),
                overwritingChanges: false,
                undo: .init(store: store, live: []),
                writer: fillsUp
            )
        }
        #expect(Fixture.read(path) == Self.text)
        let after = try #require(Fixture.modificationTime(path))
        #expect(after.tv_sec == before.tv_sec && after.tv_nsec == before.tv_nsec)
        #expect(store.held().isEmpty)
    }
}
