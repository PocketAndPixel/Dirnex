import Foundation
import Testing

@testable import DirnexCore

@Suite("LocalBackend")
struct LocalBackendTests {
    let backend = LocalBackend()

    // MARK: - Listing basics

    @Test("lists immediate children, excluding . and ..")
    func listsChildren() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("a.txt", contents: "a")
        try tree.writeFile("b.txt", contents: "bb")
        try tree.makeDir("sub")

        let names = try backend.listDirectory(at: tree.vfsPath()).map(\.name).sorted()
        #expect(names == ["a.txt", "b.txt", "sub"])
    }

    @Test("distinguishes files from directories")
    func distinguishesKinds() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("file.txt", contents: "x")
        try tree.makeDir("dir")

        let byName = try Dictionary(
            uniqueKeysWithValues: backend.listDirectory(at: tree.vfsPath()).map { ($0.name, $0) }
        )
        #expect(byName["file.txt"]?.kind == .file)
        #expect(byName["dir"]?.kind == .directory)
        #expect(byName["dir"]?.isDirectoryLike == true)
    }

    @Test("reports byte sizes")
    func reportsSizes() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("empty.bin", bytes: 0)
        try tree.writeFile("kb.bin", bytes: 1024)
        try tree.writeFile("mb.bin", bytes: 1_048_576)

        let sizes = try Dictionary(
            uniqueKeysWithValues: backend.listDirectory(at: tree.vfsPath()).map { (
                $0.name,
                $0.byteSize
            ) }
        )
        #expect(sizes["empty.bin"] == 0)
        #expect(sizes["kb.bin"] == 1024)
        #expect(sizes["mb.bin"] == 1_048_576)
    }

    @Test("entry path is a child of the listed directory")
    func entryPathIsChild() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("file.txt", contents: "x")

        let entry = try #require(try backend.listDirectory(at: tree.vfsPath()).first)
        #expect(entry.path == tree.vfsPath().appending("file.txt"))
        #expect(entry.path.parent == tree.vfsPath())
    }

    // MARK: - Hidden

    @Test("flags dotfiles as hidden")
    func flagsDotfiles() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile(".hidden", contents: "x")
        try tree.writeFile("visible.txt", contents: "x")

        let byName = try Dictionary(
            uniqueKeysWithValues: backend.listDirectory(at: tree.vfsPath()).map { (
                $0.name,
                $0.isHidden
            ) }
        )
        #expect(byName[".hidden"] == true)
        #expect(byName["visible.txt"] == false)
    }

    // MARK: - Symlinks

    @Test("classifies symlinks and resolves their target kind")
    func resolvesSymlinks() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        try tree.writeFile("target.txt", contents: "real")
        try tree.makeDir("targetdir")
        try tree.symlink("link-to-file", to: "target.txt")
        try tree.symlink("link-to-dir", to: "targetdir")
        try tree.symlink("broken", to: "does-not-exist")

        let byName = try Dictionary(
            uniqueKeysWithValues: backend.listDirectory(at: tree.vfsPath()).map { ($0.name, $0) }
        )

        let toFile = try #require(byName["link-to-file"])
        #expect(toFile.kind == .symlink)
        #expect(toFile.symlinkDestination == "target.txt")
        #expect(toFile.symlinkTargetKind == .file)
        #expect(toFile.isDirectoryLike == false)

        let toDir = try #require(byName["link-to-dir"])
        #expect(toDir.kind == .symlink)
        #expect(toDir.symlinkTargetKind == .directory)
        #expect(toDir.isDirectoryLike == true) // navigable

        let broken = try #require(byName["broken"])
        #expect(broken.kind == .symlink)
        #expect(broken.symlinkTargetKind == nil) // dangling — the target never resolved
    }

    // MARK: - Unicode / weird names

    @Test("preserves emoji, unicode, spaces and newlines in names")
    func preservesWeirdNames() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let weird = [
            "emoji 🗂️🔥.txt",
            "with spaces here.txt",
            "with\nnewline.txt",
            "cafe\u{0301}-decomposed.txt" // e + combining acute
        ]
        for name in weird {
            try tree.writeFile(name, contents: "x")
        }

        let listed = Set(try backend.listDirectory(at: tree.vfsPath()).map(\.name))
        for name in weird {
            #expect(listed.contains(name), "missing \(name.debugDescription)")
        }
    }

    // MARK: - stat

    @Test("stat returns a single entry with its kind")
    func statSingleEntry() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let filePath = try tree.writeFile("file.txt", contents: "hello")

        let entry = try backend.stat(at: .local(filePath))
        #expect(entry.name == "file.txt")
        #expect(entry.kind == .file)
        #expect(entry.byteSize == 5)
    }

    // MARK: - Errors

    @Test("listing a nonexistent path throws notFound")
    func listingMissingThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let missing = tree.vfsPath("nope")
        #expect(throws: VFSError.notFound(missing)) {
            try backend.listDirectory(at: missing)
        }
    }

    @Test("listing a file (not a directory) throws notADirectory")
    func listingFileThrows() throws {
        let tree = try TempTree()
        defer { tree.cleanup() }
        let file = try tree.writeFile("file.txt", contents: "x")
        let filePath = VFSPath.local(file)
        #expect(throws: VFSError.notADirectory(filePath)) {
            try backend.listDirectory(at: filePath)
        }
    }
}
