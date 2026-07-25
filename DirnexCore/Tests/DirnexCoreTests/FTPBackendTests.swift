import Foundation
import Testing

@testable import DirnexCore

@Suite("FTPBackend")
struct FTPBackendTests {
    private let location = FTPLocation(
        host: "nas.local",
        port: 21,
        username: "sa",
        security: .explicit
    )

    private func backend(_ transport: FakeFTPTransport) -> FTPBackend {
        FTPBackend(location: location, transport: transport)
    }

    private func path(_ remote: String) -> VFSPath {
        VFSPath(backend: .ftp(location), path: remote)
    }

    @Test("reports its account as identity and is writable but Trash-less and clone-less")
    func identityAndCapabilities() {
        let sut = backend(FakeFTPTransport())
        #expect(sut.id == .ftp(location))
        #expect(sut.capabilities == [.read, .write, .rename])
        #expect(!sut.capabilities.contains(.trash))
        #expect(!sut.capabilities.contains(.clone))
        #expect(!sut.capabilities.contains(.watch))
        // Writable + Trash-less → a delete degrades to a confirmed permanent delete (PLAN.md §M5).
        #expect(sut.capabilities(for: path("/pub")).deleteStrategy == .permanent)
    }

    @Test("lists a real captured directory into FileEntry rows with child paths")
    func listsDirectory() throws {
        let transport = FakeFTPTransport()
        transport.listings["/probe"] = FTPListingParserTests.realUnixListing
        let entries = try backend(transport).listDirectory(at: path("/probe"))

        #expect(entries.count == 6)
        let big = try #require(entries.first { $0.name == "big.bin" })
        #expect(big.kind == .file)
        #expect(big.byteSize == 3_145_728)
        #expect(big.path == path("/probe/big.bin"))

        let directory = try #require(entries.first { $0.name == "sub dir" })
        #expect(directory.isDirectory)
        #expect(directory.path == path("/probe/sub dir"))

        // A leading dot is what marks a remote row hidden; FTP reports no flag of its own.
        let hidden = try #require(entries.first { $0.name == ".hidden" })
        #expect(hidden.isHidden)
        #expect(big.isHidden == false)
    }

    /// FTP has no `LIST -d` and no `.` self row, so a stat is answered from the parent's listing.
    @Test("stats an item by finding it in its parent's listing")
    func statsFromParentListing() throws {
        let transport = FakeFTPTransport()
        transport.listings["/probe"] = FTPListingParserTests.realUnixListing
        let entry = try backend(transport).stat(at: path("/probe/big.bin"))
        #expect(entry.name == "big.bin")
        #expect(entry.kind == .file)
        #expect(entry.byteSize == 3_145_728)
        #expect(entry.path == path("/probe/big.bin"))
        // It read the *parent*, not the item.
        #expect(transport.listedPaths == ["/probe"])
    }

    @Test("stats a directory through its parent too")
    func statsDirectoryFromParentListing() throws {
        let transport = FakeFTPTransport()
        transport.listings["/probe"] = FTPListingParserTests.realUnixListing
        let entry = try backend(transport).stat(at: path("/probe/sub dir"))
        #expect(entry.kind == .directory)
        #expect(entry.name == "sub dir")
    }

    /// The root has no parent to be found in; failing there would make the connection unnavigable.
    @Test("stats the connection root without asking the server")
    func statsRootWithoutServer() throws {
        let transport = FakeFTPTransport()
        let entry = try backend(transport).stat(at: path("/"))
        #expect(entry.kind == .directory)
        #expect(transport.listedPaths.isEmpty)
    }

    @Test("a missing item is notFound, not an empty entry")
    func missingItemIsNotFound() {
        let transport = FakeFTPTransport()
        transport.listings["/probe"] = FTPListingParserTests.realUnixListing
        #expect(throws: VFSError.notFound(path("/probe/absent.txt"))) {
            try backend(transport).stat(at: path("/probe/absent.txt"))
        }
    }

    @Test("a path belonging to another backend is refused")
    func refusesForeignPaths() {
        let transport = FakeFTPTransport()
        #expect(throws: (any Error).self) {
            try backend(transport).listDirectory(at: .local("/Users/oleg"))
        }
    }

    // MARK: - Writes

    @Test("creates a remote directory")
    func createsDirectory() throws {
        let transport = FakeFTPTransport()
        try backend(transport).createDirectory(at: path("/pub/new"))
        #expect(transport.madeDirectories == ["/pub/new"])
    }

    @Test("renames within the account")
    func renamesWithinAccount() throws {
        let transport = FakeFTPTransport()
        try backend(transport).moveItem(at: path("/pub/a.txt"), to: path("/pub/b.txt"))
        #expect(transport.renames.count == 1)
        #expect(transport.renames.first?.0 == "/pub/a.txt")
        #expect(transport.renames.first?.1 == "/pub/b.txt")
    }

    /// A move off this backend is not a rename — `EXDEV` is what makes `CopyEngine` fall back to
    /// copy-then-delete, exactly as for a cross-volume local move.
    @Test("a cross-backend move throws EXDEV rather than attempting a rename")
    func crossBackendMoveThrowsEXDEV() {
        let transport = FakeFTPTransport()
        #expect(throws: VFSError.io(path: path("/pub/a.txt"), code: EXDEV)) {
            try backend(transport).moveItem(at: path("/pub/a.txt"), to: .local("/tmp/a.txt"))
        }
        #expect(transport.renames.isEmpty)
    }

    @Test("deletes a file through its parent listing")
    func deletesFile() throws {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = "-rw-r--r-- 1 sa users 6 Jul 25 20:55 a.txt"
        try backend(transport).removeItem(at: path("/pub/a.txt"))
        #expect(transport.removedFiles == ["/pub/a.txt"])
        #expect(transport.removedDirectories.isEmpty)
    }

    /// FTP has no recursive delete, so the backend empties depth-first and only then removes the
    /// directory — the deepest child must be gone before its parent is attempted.
    @Test("deletes a directory tree depth-first, children before parents")
    func deletesTreeDepthFirst() throws {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = "drwxr-xr-x 2 sa users 0 Jul 25 20:55 tree"
        transport.listings["/pub/tree"] = """
        -rw-r--r-- 1 sa users 6 Jul 25 20:55 a.txt
        drwxr-xr-x 2 sa users 0 Jul 25 20:55 inner
        """
        transport.listings["/pub/tree/inner"] = "-rw-r--r-- 1 sa users 6 Jul 25 20:55 b.txt"

        try backend(transport).removeItem(at: path("/pub/tree"))

        #expect(transport.removedFiles == ["/pub/tree/a.txt", "/pub/tree/inner/b.txt"])
        // The inner directory is removed before the outer one that contains it.
        #expect(transport.removedDirectories == ["/pub/tree/inner", "/pub/tree"])
    }

    /// A symlink is removed as a link. The kind comes from the *listing*, so nothing resolves the
    /// path and the link's target is untouched — the trap `SFTPBackend.removeItem` documents.
    @Test("a symlink is deleted as a link, not followed into its target")
    func deletesSymlinkAsLink() throws {
        let transport = FakeFTPTransport()
        transport.listings["/pub"] = "lrwxrwxrwx 1 sa users 9 Jul 25 20:55 latest -> tree"
        try backend(transport).removeItem(at: path("/pub/latest"))
        #expect(transport.removedFiles == ["/pub/latest"])
        #expect(transport.removedDirectories.isEmpty)
    }

    @Test("the connection root cannot be deleted")
    func refusesToDeleteRoot() {
        let transport = FakeFTPTransport()
        #expect(throws: VFSError.unsupported(.deleteConnectionRoot)) {
            try backend(transport).removeItem(at: path("/"))
        }
    }

    /// FTP has no verb that creates a symbolic link, so the default refusal is the right behaviour.
    @Test("creating a symbolic link is unsupported")
    func symbolicLinksAreUnsupported() {
        let transport = FakeFTPTransport()
        #expect(throws: VFSError.unsupported(.symbolicLink)) {
            try backend(transport).createSymbolicLink(
                at: path("/pub/link"),
                withDestination: "/pub/a"
            )
        }
    }
}
