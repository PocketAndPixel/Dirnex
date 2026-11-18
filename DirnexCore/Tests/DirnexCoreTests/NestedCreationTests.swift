import Foundation
import Testing

@testable import DirnexCore

/// F7 and ⇧F4 with a path for a name (2026-11-18): the folders on the way are made, a folder already
/// there is used, anything else in the way is refused by name, a failure takes back what it made,
/// and one ⌘Z removes everything one F7 made.
///
/// Run against a real scratch tree, because the answers worth pinning are the filesystem's: which
/// path `ENOTDIR` names, and what `rmdir` leaves.
@Suite("NestedCreation")
struct NestedCreationTests {
    let backend = LocalBackend()

    private static func name(_ typed: String, as leaf: NestedName.Leaf = .folder) throws -> NestedName {
        try NestedName(parsing: typed, as: leaf)
    }

    private func kind(_ tree: TempTree, _ relative: String) -> FileEntry.Kind? {
        try? backend.stat(at: tree.vfsPath(relative)).kind
    }

    private func text(_ tree: TempTree, _ relative: String) throws -> String {
        try String(contentsOfFile: tree.path(relative), encoding: .utf8)
    }

    // MARK: - F7

    @Test("F7 makes every folder on the way and the named one, outermost first")
    func makesTheWholeChain() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let made = try NestedCreation.makeFolder(
            Self.name("folder A/sub folder A/deeper"), in: tree.vfsPath(), using: backend
        )

        #expect(made == [
            tree.vfsPath("folder A"),
            tree.vfsPath("folder A/sub folder A"),
            tree.vfsPath("folder A/sub folder A/deeper")
        ])
        #expect(kind(tree, "folder A/sub folder A/deeper") == .directory)
    }

    @Test("a plain name is made exactly as before")
    func plainName() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let made = try NestedCreation.makeFolder(
            Self.name("untitled folder"),
            in: tree.vfsPath(),
            using: backend
        )

        #expect(made == [tree.vfsPath("untitled folder")])
    }

    /// What is returned is what the undo removes, so a folder that was already there must not be in
    /// it, or ⌘Z would remove a folder this F7 did not make the moment it was empty.
    @Test("a folder already on the way is used, and not counted as made")
    func usesAnExistingFolder() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("folder A")
        try tree.writeFile("folder A/kept.txt", contents: "mine")

        let made = try NestedCreation.makeFolder(
            Self.name("folder A/sub"),
            in: tree.vfsPath(),
            using: backend
        )

        #expect(made == [tree.vfsPath("folder A/sub")])
        #expect(try text(tree, "folder A/kept.txt") == "mine")
    }

    @Test("a symlink to a folder on the way is used, as mkdir -p uses it")
    func usesALinkedFolder() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("real")
        try tree.symlink("link", to: tree.path("real"))

        let made = try NestedCreation.makeFolder(
            Self.name("link/inside"),
            in: tree.vfsPath(),
            using: backend
        )

        #expect(made == [tree.vfsPath("link/inside")])
        #expect(kind(tree, "real/inside") == .directory)
    }

    @Test("the named folder already there is refused, as F7 always refused it")
    func refusesAnExistingLeaf() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("a/b")

        #expect(throws: VFSError.alreadyExists(tree.vfsPath("a/b"))) {
            try NestedCreation.makeFolder(Self.name("a/b"), in: tree.vfsPath(), using: backend)
        }
    }

    /// `mkdir(2)` under a file answers `ENOTDIR` naming the path it was given, so without the read on
    /// the way the sentence would be about `sub`, which is not what is wrong.
    @Test("a file on the way is refused naming the file, and nothing is made")
    func refusesAFileOnTheWay() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("notes", contents: "keep")

        #expect(throws: VFSError.notADirectory(tree.vfsPath("notes"))) {
            try NestedCreation.makeFolder(
                Self.name("notes/sub/deeper"),
                in: tree.vfsPath(),
                using: backend
            )
        }
        #expect(try text(tree, "notes") == "keep")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path) == ["notes"])
    }

    /// The failure comes after two folders are made: a name longer than APFS takes (`ENAMETOOLONG`,
    /// probed 2026-11-18). A refused F7 records no undo, so anything left here would stay.
    @Test("a failure takes back the folders it made")
    func takesBackOnFailure() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("existing")
        let tooLong = String(repeating: "n", count: 300)

        #expect(throws: VFSError.self) {
            try NestedCreation.makeFolder(
                Self.name("existing/new/newer/\(tooLong)"), in: tree.vfsPath(), using: backend
            )
        }
        // Its own two are gone; the one that was there stays.
        #expect(kind(tree, "existing") == .directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.path("existing")).isEmpty)
    }

    // MARK: - ⇧F4

    @Test("⇧F4 makes the folders on the way and an empty file")
    func makesAFileInNewFolders() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let made = try NestedCreation.makeFile(
            Self.name("Folder A/test.txt", as: .file), in: tree.vfsPath(), using: backend
        )

        #expect(made == [tree.vfsPath("Folder A")])
        #expect(kind(tree, "Folder A/test.txt") == .file)
        #expect(try text(tree, "Folder A/test.txt").isEmpty)
    }

    @Test("a file already there is refused and keeps its bytes, and nothing is made")
    func refusesAnExistingFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("a")
        try tree.writeFile("a/test.txt", contents: "document")

        #expect(throws: VFSError.alreadyExists(tree.vfsPath("a/test.txt"))) {
            try NestedCreation.makeFile(
                Self.name("a/test.txt", as: .file),
                in: tree.vfsPath(),
                using: backend
            )
        }
        #expect(try text(tree, "a/test.txt") == "document")
    }

    @Test("a file that fails takes back the folders made for it")
    func fileFailureTakesBack() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let tooLong = String(repeating: "n", count: 300) + ".txt"

        #expect(throws: VFSError.self) {
            try NestedCreation.makeFile(
                Self.name("a/b/\(tooLong)", as: .file),
                in: tree.vfsPath(),
                using: backend
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path).isEmpty)
    }

    // MARK: - A backend whose folder create cannot refuse

    /// S3's `createDirectory` succeeds over a folder that is there, so only the read on the way says
    /// whether this create made it. Without it, `existing` would come back as made, and ⌘Z would
    /// remove a folder this F7 never made.
    @Test("over an idempotent folder create, a folder already there is not counted as made")
    func idempotentBackend() throws {
        let backend = FolderSetBackend(folders: ["/", "/existing"])
        let root = VFSPath(backend: backend.id, path: "/")

        let made = try NestedCreation.makeFolder(Self.name("existing/new"), in: root, using: backend)

        #expect(made.map(\.path) == ["/existing/new"])
        #expect(backend.createCalls == ["/existing/new"])
    }

    // MARK: - Undo

    @Test("one undo removes the whole chain, and redo makes it again")
    func undoAndRedo() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let made = try NestedCreation.makeFolder(
            Self.name("a/b/c"),
            in: tree.vfsPath(),
            using: backend
        )
        let record = try #require(UndoRecord.newFolders(made))

        #expect(record.label == .newFolder)
        #expect(UndoJournal.revert(record, using: backend).succeeded)
        #expect(try FileManager.default.contentsOfDirectory(atPath: tree.root.path).isEmpty)

        #expect(UndoJournal.revert(record.inverted, using: backend).succeeded)
        #expect(kind(tree, "a/b/c") == .directory)
    }

    @Test("undo leaves every folder that has something put in it since")
    func undoKeepsFilledFolders() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let made = try NestedCreation.makeFolder(
            Self.name("a/b/c"),
            in: tree.vfsPath(),
            using: backend
        )
        try tree.writeFile("a/added.txt", contents: "mine")
        let record = try #require(UndoRecord.newFolders(made))

        #expect(UndoJournal.revert(record, using: backend).succeeded)

        // `c` and `b` were empty and go; `a` holds the user's file and stays, with it.
        #expect(kind(tree, "a/b") == nil)
        #expect(try text(tree, "a/added.txt") == "mine")
    }

    @Test("nothing made is nothing to undo")
    func nothingToUndo() {
        #expect(UndoRecord.newFolders([]) == nil)
    }
}

/// Folders held as a set, whose `createDirectory` succeeds whether or not the folder is there, as
/// S3's does, and which records what it was asked to create.
private final class FolderSetBackend: VFSBackend, @unchecked Sendable {
    let id = VFSBackendID("s3://idempotent")
    let capabilities: VFSCapabilities = [.read, .write]

    private let lock = NSLock()
    private var folders: Set<String>
    private var calls: [String] = []

    init(folders: Set<String>) {
        self.folders = folders
    }

    var createCalls: [String] { lock.withLock { calls } }

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        guard lock.withLock({ folders.contains(path.path) }) else { throw VFSError.notFound(path) }
        return FileEntry(
            path: path, name: path.lastComponent, kind: .directory, byteSize: 0,
            modificationDate: .distantPast, creationDate: .distantPast, isHidden: false,
            permissions: nil, inode: 0
        )
    }

    func createDirectory(at path: VFSPath) throws {
        lock.withLock {
            calls.append(path.path)
            folders.insert(path.path)
        }
    }
}
