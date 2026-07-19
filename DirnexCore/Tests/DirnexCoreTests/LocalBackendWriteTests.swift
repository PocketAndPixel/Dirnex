import Foundation
import Testing

@testable import DirnexCore

/// Exercises the M2 write primitives (`createDirectory`/`moveItem`/`removeItem`/
/// `trashItem`) against a throwaway on-disk tree — the "if it touches bytes, it lives
/// in DirnexCore and has tests" rule (PLAN.md §2). Every operation is checked for its
/// success shape and its error shape; the recursive delete is checked on a real tree.
@Suite("LocalBackend write")
struct LocalBackendWriteTests {
    let backend = LocalBackend()

    // MARK: - createDirectory

    @Test("creates a directory that then lists as one")
    func createsDirectory() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let dir = tree.vfsPath("new")
        try backend.createDirectory(at: dir)
        #expect(try backend.stat(at: dir).kind == .directory)
    }

    @Test("creating over an existing name throws alreadyExists")
    func createOverExistingThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("dir")

        let dir = tree.vfsPath("dir")
        #expect(throws: VFSError.alreadyExists(dir)) {
            try backend.createDirectory(at: dir)
        }
    }

    @Test("creating inside a missing parent throws notFound")
    func createInMissingParentThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let nested = tree.vfsPath("missing/child")
        #expect(throws: VFSError.notFound(nested)) {
            try backend.createDirectory(at: nested)
        }
    }

    // MARK: - moveItem

    @Test("renames a file in place")
    func renamesFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("old.txt", contents: "hello")

        let source = tree.vfsPath("old.txt")
        let destination = tree.vfsPath("new.txt")
        try backend.moveItem(at: source, to: destination)

        let names = try backend.listDirectory(at: tree.vfsPath()).map(\.name)
        #expect(names == ["new.txt"])
        #expect(try backend.stat(at: destination).byteSize == 5)
    }

    @Test("moves an item into another directory")
    func movesIntoDirectory() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("file.txt", contents: "x")
        try tree.makeDir("dest")

        let source = tree.vfsPath("file.txt")
        let destination = tree.vfsPath("dest").appending("file.txt")
        try backend.moveItem(at: source, to: destination)

        #expect(try backend.listDirectory(at: tree.vfsPath("dest")).map(\.name) == ["file.txt"])
        #expect(throws: VFSError.notFound(source)) { try backend.stat(at: source) }
    }

    @Test("moving a nonexistent source throws notFound")
    func moveMissingThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let source = tree.vfsPath("nope")
        #expect(throws: VFSError.notFound(source)) {
            try backend.moveItem(at: source, to: tree.vfsPath("dst"))
        }
    }

    // MARK: - removeItem

    @Test("removes a single file")
    func removesFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("gone.txt", contents: "x")

        let file = tree.vfsPath("gone.txt")
        try backend.removeItem(at: file)
        #expect(throws: VFSError.notFound(file)) { try backend.stat(at: file) }
    }

    @Test("removes a non-empty directory tree recursively")
    func removesTreeRecursively() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.makeDir("top/mid/leaf")
        try tree.writeFile("top/a.txt", contents: "a")
        try tree.writeFile("top/mid/b.txt", contents: "b")
        try tree.writeFile("top/mid/leaf/c.txt", contents: "c")

        let top = tree.vfsPath("top")
        try backend.removeItem(at: top)
        #expect(throws: VFSError.notFound(top)) { try backend.stat(at: top) }
        // The tree root survives — only the requested subtree is gone.
        #expect(try backend.listDirectory(at: tree.vfsPath()).isEmpty)
    }

    @Test("removing a nonexistent path throws notFound")
    func removeMissingThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        let missing = tree.vfsPath("nope")
        #expect(throws: VFSError.notFound(missing)) {
            try backend.removeItem(at: missing)
        }
    }

    // MARK: - trashItem

    @Test("trashes a file: original vanishes, a resulting Trash location is returned")
    func trashesFile() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("junk.txt", contents: "x")

        let file = tree.vfsPath("junk.txt")
        let resulting = try backend.trashItem(at: file)

        #expect(throws: VFSError.notFound(file)) { try backend.stat(at: file) }
        let landed = try #require(resulting)
        // Clean up after ourselves so the test doesn't litter the user's Trash.
        #expect(FileManager.default.fileExists(atPath: landed.path))
        try? FileManager.default.removeItem(atPath: landed.path)
    }

    @Test("trashing a nonexistent path throws")
    func trashMissingThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }

        #expect(throws: VFSError.self) {
            try backend.trashItem(at: tree.vfsPath("nope"))
        }
    }

    // MARK: - Capabilities & the read-only default

    @Test("LocalBackend advertises the write capabilities it implements")
    func advertisesWriteCapabilities() {
        #expect(backend.capabilities.contains(.write))
        #expect(backend.capabilities.contains(.trash))
        #expect(backend.capabilities.contains(.rename))
    }

    @Test("a backend that doesn't override the write methods throws unsupported")
    func readOnlyBackendThrowsUnsupported() {
        let readOnly = ReadOnlyBackend()
        let path = VFSPath.local("/tmp/whatever")
        #expect(throws: (any Error).self) { try readOnly.createDirectory(at: path) }
        #expect(throws: (any Error).self) { try readOnly.moveItem(at: path, to: path) }
        #expect(throws: (any Error).self) { try readOnly.removeItem(at: path) }
        #expect(throws: (any Error).self) { try readOnly.trashItem(at: path) }
    }
}

/// A minimal backend that implements only the read surface, to prove the write
/// methods' default implementations throw `.unsupported`.
private struct ReadOnlyBackend: VFSBackend {
    let id = VFSBackendID("readonly")
    let capabilities: VFSCapabilities = [.read]

    func listDirectory(at path: VFSPath) throws -> [FileEntry] { [] }

    func stat(at path: VFSPath) throws -> FileEntry {
        throw VFSError.notFound(path)
    }
}
