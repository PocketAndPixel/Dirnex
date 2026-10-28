import Foundation
import Testing

@testable import DirnexCore

/// Which `#recycle` a WebDAV delete may land in (``ShareRecycleBin/webDAVBin(catching:)``): the one
/// at the root of the shared folder, the server path's first segment, as on the NAS.
@Suite("ShareRecycleBin over WebDAV")
struct ShareRecycleBinWebDAVTests {
    private static let nas = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let atHome = WebDAVLocation(
        host: "nas",
        port: 5006,
        username: "dirnex-test",
        rootPath: "/home"
    )

    private func path(_ path: String, on location: WebDAVLocation = Self.nas) -> VFSPath {
        VFSPath(backend: location.backendID, path: path)
    }

    private func bin(_ paths: [VFSPath]) -> String? {
        ShareRecycleBin.webDAVBin(catching: paths)?.path
    }

    @Test("an item anywhere in a share is caught by the share's own bin")
    func insideAShare() {
        #expect(bin([path("/home/notes.txt")]) == "/home/#recycle")
        #expect(bin([path("/home/a/b/deep.txt")]) == "/home/#recycle")
        #expect(bin([path("/home/a"), path("/home/b/c")]) == "/home/#recycle")
        #expect(bin([path("/share/x")]) == "/share/#recycle")
    }

    @Test("a share, the account root, and anything already in a bin have none")
    func noBin() {
        #expect(bin([path("/home")]) == nil)
        #expect(bin([path("/")]) == nil)
        #expect(bin([path("/home/#recycle")]) == nil)
        #expect(bin([path("/home/#recycle/notes.txt")]) == nil)
        #expect(bin([path("/home/a/#recycle/b")]) == nil, "any bin component is the strong warning")
        #expect(bin([]) == nil)
    }

    @Test("a set spread over two shares, two accounts or another backend has none")
    func mixedSets() {
        #expect(bin([path("/home/a"), path("/share/b")]) == nil)
        #expect(bin([path("/home/a"), path("/x", on: Self.atHome)]) == nil)
        #expect(bin([path("/home/a"), .local("/Volumes/home/a")]) == nil)
        #expect(bin([.local("/Volumes/home/a")]) == nil)
        let sftp = VFSPath(backend: VFSBackendID("sftp://dirnex-test@nas:22"), path: "/home/a")
        #expect(bin([sftp]) == nil)
    }

    @Test("a root at a share finds the bin at its own root; a root inside one cannot see it")
    func rootedLocations() {
        #expect(bin([path("/notes.txt", on: Self.atHome)]) == "/#recycle")
        #expect(bin([path("/", on: Self.atHome)]) == nil)
        let deeper = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "u",
            rootPath: "/home/projects"
        )
        #expect(bin([path("/notes.txt", on: deeper)]) == nil)
    }

    @Test("Nextcloud's root is deep, so no #recycle is named for it")
    func nextcloud() {
        let cloud = WebDAVLocation(
            host: "cloud.example.com",
            username: "me@example.com",
            rootPath: "/remote.php/dav/files/me@example.com"
        )
        #expect(bin([path("/Documents/report.pdf", on: cloud)]) == nil)
    }

    /// The share is the segment as stored, compared as bytes: two spellings of é are two shares.
    @Test("the bin is named on the share's own spelling")
    func spelling() {
        let composed = bin([path("/caf\u{E9}/a")])
        let decomposed = bin([path("/cafe\u{301}/a")])
        #expect(composed.map { Array($0.utf8) } == Array("/caf\u{E9}/#recycle".utf8))
        #expect(decomposed.map { Array($0.utf8) } == Array("/cafe\u{301}/#recycle".utf8))
    }
}
