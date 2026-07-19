import Foundation
import Testing

@testable import DirnexCore

@Suite("ArchiveBackend")
struct ArchiveBackendTests {
    private let listing = """
    -rw-r--r--  0 501    20         11 Jul 10 16:19 alpha.txt
    drwxr-xr-x  0 501    20          0 Jul 10 16:19 folder/
    -rw-r--r--  0 501    20         17 Jul 10 16:19 folder/beta.txt
    """

    private func makeBackend(at path: String = "/Users/me/pkg.zip") -> ArchiveBackend {
        ArchiveBackend(archiveOnDiskPath: path, toc: ArchiveTOC(verboseListing: listing))
    }

    @Test("id encodes the archive path and round-trips")
    func idEncodesPath() {
        let backend = makeBackend(at: "/Users/me/pkg.zip")
        #expect(backend.id.isArchive)
        #expect(backend.id.archivePath == "/Users/me/pkg.zip")
    }

    @Test("read-only capabilities")
    func capabilities() {
        let backend = makeBackend()
        #expect(backend.capabilities == .read)
        #expect(!backend.capabilities.contains(.write))
        #expect(!backend.capabilities.contains(.rename))
        #expect(!backend.capabilities.contains(.watch))
    }

    @Test("listing the root returns archive-scoped entries")
    func listRoot() throws {
        let backend = makeBackend()
        let root = VFSPath(backend: backend.id, path: "/")
        let entries = try backend.listDirectory(at: root)
        #expect(Set(entries.map(\.name)) == ["alpha.txt", "folder"])

        let alpha = try #require(entries.first { $0.name == "alpha.txt" })
        #expect(alpha.path.backend == backend.id)
        #expect(alpha.path.path == "/alpha.txt")
        #expect(alpha.byteSize == 11)
        #expect(alpha.kind == .file)

        let folder = try #require(entries.first { $0.name == "folder" })
        #expect(folder.isDirectoryLike)
    }

    @Test("listing a subdirectory works")
    func listSubdirectory() throws {
        let backend = makeBackend()
        let folder = VFSPath(backend: backend.id, path: "/folder")
        let entries = try backend.listDirectory(at: folder)
        #expect(entries.map(\.name) == ["beta.txt"])
        #expect(entries.first?.path.path == "/folder/beta.txt")
    }

    @Test("stat resolves a file and the root directory")
    func statResolves() throws {
        let backend = makeBackend()
        let beta = try backend.stat(at: VFSPath(backend: backend.id, path: "/folder/beta.txt"))
        #expect(beta.name == "beta.txt")
        #expect(beta.byteSize == 17)

        let root = try backend.stat(at: VFSPath(backend: backend.id, path: "/"))
        #expect(root.isDirectory)
    }

    @Test("listing a file throws notADirectory")
    func listFileThrows() {
        let backend = makeBackend()
        #expect(throws: VFSError.notADirectory(VFSPath(backend: backend.id, path: "/alpha.txt"))) {
            try backend.listDirectory(at: VFSPath(backend: backend.id, path: "/alpha.txt"))
        }
    }

    @Test("stat of a missing path throws notFound")
    func statMissingThrows() {
        let backend = makeBackend()
        let ghost = VFSPath(backend: backend.id, path: "/nope.txt")
        #expect(throws: VFSError.notFound(ghost)) {
            try backend.stat(at: ghost)
        }
    }

    @Test("a path from another backend is rejected")
    func foreignPathRejected() {
        let backend = makeBackend()
        #expect(throws: (any Error).self) {
            try backend.listDirectory(at: .local("/folder"))
        }
    }

    @Test("write primitives are unsupported")
    func writesUnsupported() {
        let backend = makeBackend()
        let target = VFSPath(backend: backend.id, path: "/new")
        #expect(throws: (any Error).self) { try backend.createDirectory(at: target) }
        #expect(throws: (any Error).self) { try backend.removeItem(at: target) }
        #expect(throws: (any Error).self) {
            try backend.moveItem(at: VFSPath(backend: backend.id, path: "/alpha.txt"), to: target)
        }
    }
}

@Suite("ArchiveType")
struct ArchiveTypeTests {
    @Test("recognizes browsable archive suffixes")
    func browsable() {
        for name in [
            "pkg.zip",
            "Backup.TGZ",
            "src.tar.gz",
            "photos.tar",
            "lib.jar",
            "book.cbz",
            "data.7z"
        ] {
            #expect(ArchiveType.isBrowsable(name), "expected \(name) to be browsable")
        }
    }

    @Test("rejects non-archives and bare dotfile-suffix names")
    func notBrowsable() {
        for name in ["notes.txt", "image.png", "archive", ".zip", ".tar.gz", "song.gz"] {
            #expect(!ArchiveType.isBrowsable(name), "expected \(name) to be rejected")
        }
    }
}
