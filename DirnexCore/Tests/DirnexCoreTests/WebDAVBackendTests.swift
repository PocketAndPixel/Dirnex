import Foundation
import Testing

@testable import DirnexCore

/// The read half of the WebDAV backend against a fake fed the NAS's bytes (PLAN.md §M32 Slice 2):
/// listing, the stat rule, the fallback that names a file, downloads with resume, and the
/// classification of what a run answered.
@Suite("WebDAV backend")
struct WebDAVBackendTests {
    private static let location = WebDAVLocation(host: "nas", port: 5006, username: "dirnex-test")
    private static let folder = "/home/dirnex-webdav-fixture"
    private static let file = folder + "/Привет мир.txt"

    private func path(_ path: String, in location: WebDAVLocation = Self.location) -> VFSPath {
        VFSPath(backend: location.backendID, path: path)
    }

    private func backend(_ transport: FakeWebDAVTransport, location: WebDAVLocation = Self.location)
        -> WebDAVBackend {
        WebDAVBackend(location: location, transport: transport)
    }

    // MARK: - Listing

    @Test("a folder lists from real bytes, one Depth 1 request naming it as a collection")
    func listsAFolder() throws {
        let transport = FakeWebDAVTransport { _ in try WebDAVFixtures.multistatus("nas-folder-props") }
        let entries = try backend(transport).listDirectory(at: path(Self.folder))

        #expect(transport.propfinds == [.init(path: Self.folder, depth: .one, isCollection: true)])
        #expect(Set(entries.map { Array($0.name.utf8) }) == WebDAVFixtures.folderNames)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(byName["Папка"]?.kind == .directory)
        #expect(byName["empty.txt"]?.byteSize == 0)
        #expect(byName["Привет мир.txt"]?.byteSize == 6)
        #expect(byName["Привет мир.txt"]?.path == path(Self.file))
        #expect(byName[".hidden"]?.isHidden == true)
        #expect(byName["a#b%c;d+e?f&g=h[1].txt"] != nil, "a + is a plus, not a space")
    }

    @Test("the pane's paths are mapped under the root, and the rows come back out of it")
    func rootPathMapping() throws {
        let rooted = WebDAVLocation(
            host: "nas",
            port: 5006,
            username: "dirnex-test",
            rootPath: "/home"
        )
        let transport = FakeWebDAVTransport { _ in try WebDAVFixtures.multistatus("nas-folder-props") }
        let entries = try backend(transport, location: rooted)
            .listDirectory(at: path("/dirnex-webdav-fixture", in: rooted))

        #expect(transport.propfinds.first?.path == "/dirnex-webdav-fixture")
        #expect(entries.count == 8)
        #expect(entries.allSatisfy { $0.path.parent == path("/dirnex-webdav-fixture", in: rooted) })
    }

    @Test("the account root lists its shared folders, which carry no trailing slash")
    func accountRoot() throws {
        let transport = FakeWebDAVTransport { _ in try WebDAVFixtures.multistatus("nas-root-props") }
        let entries = try backend(transport).listDirectory(at: path("/"))
        #expect(Set(entries.map(\.name)) == ["home", "share", "media"])
        #expect(entries.allSatisfy { $0.kind == .directory })
    }

    /// Apache answers a file named as a collection with a bare 400, measured on the NAS; the
    /// fallback stat without the slash is what turns that into the error a pane can act on.
    @Test("listing a file is notADirectory, found by a stat after Apache's 400")
    func listingAFile() throws {
        let transport = FakeWebDAVTransport { request in
            request.depth == .one
                ? try WebDAVFixtures.run(
                    "curl-exit0-nas-propfind-file-slash-400",
                    body: "nas-file-as-collection-400",
                    bodyExtension: "html"
                )
                : try WebDAVFixtures.multistatus("nas-file-depth0-props")
        }
        #expect(throws: VFSError.notADirectory(path(Self.file))) {
            try backend(transport).listDirectory(at: path(Self.file))
        }
        #expect(transport.propfinds == [
            .init(path: Self.file, depth: .one, isCollection: true),
            .init(path: Self.file, depth: .zero, isCollection: false)
        ])
    }

    @Test("a missing folder is notFound, and a refusal is not followed by a stat")
    func missingAndRefused() throws {
        let missing = FakeWebDAVTransport { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nas-propfind-404",
                body: "nas-missing-404",
                bodyExtension: "html"
            )
        }
        #expect(throws: VFSError.notFound(path("/home/gone"))) {
            try backend(missing).listDirectory(at: path("/home/gone"))
        }

        let refused = FakeWebDAVTransport { _ in try WebDAVFixtures.run(
            "curl-exit0-nas-propfind-401"
        ) }
        #expect(throws: VFSError.permissionDenied(path("/home"))) {
            try backend(refused).listDirectory(at: path("/home"))
        }
        #expect(refused.propfinds.count == 1)
    }

    @Test("a listing whose own row is a file is notADirectory")
    func listingAnsweredWithAFile() {
        let transport = FakeWebDAVTransport { _ in try WebDAVFixtures.multistatus(
            "nas-file-depth0-props"
        ) }
        #expect(throws: VFSError.notADirectory(path(Self.file))) {
            try backend(transport).listDirectory(at: path(Self.file))
        }
    }

    @Test("a 2xx that is not a multistatus is an I/O failure, never an empty folder")
    func notAMultistatus() {
        let transport = FakeWebDAVTransport { _ in
            WebDAVHTTPResponse(status: 200, body: Data("<html>DSM</html>".utf8))
        }
        #expect(throws: VFSError.io(path: path("/home"), code: EIO)) {
            try backend(transport).listDirectory(at: path("/home"))
        }
    }

    @Test("no answer is an I/O failure at the path")
    func transportFailure() {
        let transport = FakeWebDAVTransport { _ in try WebDAVFixtures.run("curl-exit28-unreachable") }
        #expect(throws: VFSError.io(path: path("/home"), code: EIO)) {
            try backend(transport).listDirectory(at: path("/home"))
        }
    }

    @Test("a path from another connection never reaches the wire")
    func otherConnection() {
        let transport = FakeWebDAVTransport()
        let other = WebDAVLocation(host: "nas", port: 5006, username: "oleg")
        #expect(throws: VFSError.self) {
            try backend(transport).listDirectory(at: path("/home", in: other))
        }
        #expect(transport.propfinds.isEmpty)
    }

    // MARK: - Stat

    @Test("a stat is one Depth 0 request without the slash, read into an entry")
    func statsAFile() throws {
        let transport = FakeWebDAVTransport { _ in try WebDAVFixtures.multistatus(
            "nas-file-depth0-props"
        ) }
        let entry = try backend(transport).stat(at: path(Self.file))
        #expect(transport.propfinds == [.init(path: Self.file, depth: .zero, isCollection: false)])
        #expect(entry.kind == .file)
        #expect(entry.name == "Привет мир.txt")
        #expect(entry.byteSize == 6)
        #expect(entry.modificationDate == WebDAVFixtures.nasStamp)
        #expect(entry.entityTag == #""6-65e73fc5642b9""#)
    }

    @Test("a folder named without its slash stats as a folder")
    func statsAFolder() throws {
        let transport = FakeWebDAVTransport { _ in
            try WebDAVFixtures.multistatus("nas-folder-noslash-depth0-props")
        }
        #expect(try backend(transport).stat(at: path(Self.folder)).kind == .directory)
    }

    @Test("a missing path stats as notFound")
    func statMissing() {
        let transport = FakeWebDAVTransport { _ in
            try WebDAVFixtures.run(
                "curl-exit0-nas-propfind-404",
                body: "nas-missing-404",
                bodyExtension: "html"
            )
        }
        #expect(throws: VFSError.notFound(path("/home/gone"))) {
            try backend(transport).stat(at: path("/home/gone"))
        }
    }

    @Test("the root is answered without asking, named after the host")
    func statRoot() throws {
        let transport = FakeWebDAVTransport()
        let root = try backend(transport).stat(at: path("/"))
        #expect(root.kind == .directory)
        #expect(root.name == "nas")
        #expect(transport.propfinds.isEmpty)
    }

    // MARK: - Capabilities

    /// No `.trash`, so F8 is a confirmed permanent delete; no `.internalCopy`, since COPY is
    /// attempted rather than promised; nothing editable in Get Info, since no request sets a time.
    @Test("writable and renamed in place, with no Trash and nothing promised about COPY")
    func capabilities() {
        let backend = backend(FakeWebDAVTransport())
        #expect(backend.capabilities == [.read, .write, .rename])
        #expect(backend.capabilities.deleteStrategy == .permanent)
        #expect(backend.editableMetadata(at: path("/home/a.txt")).isEmpty)
        #expect(backend.mayAttemptInternalCopy(from: path("/home/a.txt"), to: path("/home/b.txt")))
    }

    @Test("two roots on one server are one volume, another port is another")
    func volumes() {
        let home = WebDAVBackend(
            location: WebDAVLocation(
                host: "nas",
                port: 5006,
                username: "dirnex-test",
                rootPath: "/home"
            ),
            transport: FakeWebDAVTransport()
        )
        let share = WebDAVBackend(
            location: WebDAVLocation(
                host: "nas",
                port: 5006,
                username: "dirnex-test",
                rootPath: "/share"
            ),
            transport: FakeWebDAVTransport()
        )
        let plain = WebDAVBackend(
            location: WebDAVLocation(
                host: "nas",
                port: 5005,
                username: "dirnex-test",
                usesTLS: false
            ),
            transport: FakeWebDAVTransport()
        )
        let some = path("/x")
        #expect(home.volumeIdentifier(for: some) == share.volumeIdentifier(for: some))
        #expect(home.volumeIdentifier(for: some) != plain.volumeIdentifier(for: some))
    }
}
