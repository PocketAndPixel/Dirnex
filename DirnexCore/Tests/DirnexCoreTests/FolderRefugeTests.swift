import Foundation
import Testing
@testable import DirnexCore

/// Where a pane goes when its folder is deleted under it (`FolderRefuge`).
///
/// The `stat` is scripted per path and records what it was asked, so each test can say both where
/// the walk ended and that it asked nothing past the answer.
@Suite("Folder refuge")
struct FolderRefugeTests {
    private static let server = VFSBackendID("sftp://user@host")

    private static func path(_ string: String) -> VFSPath {
        VFSPath(backend: server, path: string)
    }

    private static func entry(_ path: VFSPath, kind: FileEntry.Kind) -> FileEntry {
        FileEntry(
            path: path,
            name: path.lastComponent,
            kind: kind,
            byteSize: 0,
            modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            isHidden: false,
            permissions: 0o755,
            inode: 1
        )
    }

    /// A `stat` answering from `folders` and `files`, throwing `failures[path]` where one is given
    /// and `notFound` for everything else, and logging every path it was asked about.
    private final class Server {
        var folders: Set<String> = []
        var files: Set<String> = []
        var failures: [String: VFSError] = [:]
        private(set) var asked: [String] = []

        func stat(_ path: VFSPath) throws -> FileEntry {
            asked.append(path.path)
            if let failure = failures[path.path] { throw failure }
            if folders.contains(path.path) { return FolderRefugeTests.entry(path, kind: .directory) }
            if files.contains(path.path) { return FolderRefugeTests.entry(path, kind: .file) }
            throw VFSError.notFound(path)
        }

        func refuge(above path: String) -> String? {
            FolderRefuge.nearestExisting(above: FolderRefugeTests.path(path), stat: stat)?.path
        }
    }

    @Test("a folder deleted under the pane sends it to its parent")
    func parentOfAGoneFolder() {
        let server = Server()
        server.folders = ["/", "/home", "/home/project"]
        #expect(server.refuge(above: "/home/project/build") == "/home/project")
        #expect(server.asked == ["/home/project/build", "/home/project"])
    }

    @Test("a chain deleted together sends it to the nearest folder left, and no further")
    func nearestOfSeveral() {
        let server = Server()
        server.folders = ["/", "/home"]
        #expect(server.refuge(above: "/home/project/build/out") == "/home")
        #expect(
            server.asked == [
                "/home/project/build/out",
                "/home/project/build",
                "/home/project",
                "/home"
            ]
        )
    }

    @Test("a folder that is still there keeps the pane where it is")
    func folderStillThere() {
        // FTP reads a 550 as `notFound` for a folder the account may no longer open: the listing
        // failed, but the folder answers, so nothing moves.
        let server = Server()
        server.folders = ["/", "/home", "/home/locked"]
        #expect(server.refuge(above: "/home/locked") == nil)
        #expect(server.asked == ["/home/locked"])
    }

    @Test("a folder that cannot be asked about keeps the pane where it is")
    func folderUnreachable() {
        let server = Server()
        server.folders = ["/", "/home"]
        server.failures["/home/project"] = .io(path: Self.path("/home/project"), code: ETIMEDOUT)
        #expect(server.refuge(above: "/home/project") == nil)
        #expect(server.asked == ["/home/project"])
    }

    @Test("an ancestor that cannot be asked about stops the walk rather than being skipped")
    func ancestorUnreachable() {
        let server = Server()
        server.folders = ["/", "/home"]
        server.failures["/home/project"] = .permissionDenied(Self.path("/home/project"))
        #expect(server.refuge(above: "/home/project/build") == nil)
        #expect(server.asked == ["/home/project/build", "/home/project"])
    }

    @Test("a file where the folder was counts as gone")
    func fileInPlaceOfTheFolder() {
        let server = Server()
        server.folders = ["/", "/home"]
        server.files = ["/home/project"]
        #expect(server.refuge(above: "/home/project") == "/home")
    }

    @Test("a walk that finds nothing up to the root keeps the pane where it is")
    func nothingUpToTheRoot() {
        let server = Server()
        #expect(server.refuge(above: "/home/project") == nil)
        #expect(server.asked == ["/home/project", "/home", "/"])
    }

    @Test("the root itself is a refuge when it answers")
    func rootAnswers() {
        let server = Server()
        server.folders = ["/"]
        #expect(server.refuge(above: "/gone") == "/")
    }
}
