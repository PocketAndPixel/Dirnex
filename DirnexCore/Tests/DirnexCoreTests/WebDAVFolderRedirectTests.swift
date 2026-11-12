import Foundation
import Testing

@testable import DirnexCore

/// A stock Debian Apache's redirect of a folder named without its slash (PLAN.md §M38), read off
/// `curl-exit0-debian-…`: the core's own builders run through the real `curl` against Apache 2.4.68
/// with `DirectorySlash` on (2026-11-10), at `localhost:8092` under `/plain/fx`.
@Suite("WebDAV: a folder redirected to its slash")
struct WebDAVFolderRedirectTests {
    private static let location = WebDAVLocation(
        host: "localhost",
        port: 8092,
        username: "",
        usesTLS: false,
        rootPath: "/plain/fx"
    )

    private func path(_ path: String) -> VFSPath {
        VFSPath(backend: Self.location.backendID, path: path)
    }

    private func backend(_ transport: FakeWebDAVTransport) -> WebDAVBackend {
        WebDAVBackend(location: Self.location, transport: transport)
    }

    static func debian(_ name: String, body: String? = nil) throws -> WebDAVHTTPResponse {
        try WebDAVFixtures.run("curl-exit0-debian-\(name)", body: body)
    }

    /// A fake answering each write from `answers`, in order, by what was asked.
    private func transport(
        _ answers: @escaping (FakeWebDAVTransport.Write) throws -> WebDAVHTTPResponse
    ) -> FakeWebDAVTransport {
        let transport = FakeWebDAVTransport()
        transport.answerWrite = answers
        return transport
    }

    // MARK: - Reading the answer

    @Test("a redirect to the same path with its slash asks for the folder's spelling")
    func readsTheRedirect() throws {
        let redirect = try Self.debian("propfind-folder-301")
        #expect(WebDAVFolderRedirect.asksForCollection(redirect, at: "/plain/fx/photos"))
        // The same answer is not about another path, the root above it included.
        #expect(!WebDAVFolderRedirect.asksForCollection(redirect, at: "/plain/fx/pictures"))
        #expect(!WebDAVFolderRedirect.asksForCollection(redirect, at: "/plain/fx"))
        // A folder's own answer, and a refusal, ask for nothing.
        let listing = try Self.debian("propfind-folder-207", body: "debian-photos-depth0-props")
        #expect(!WebDAVFolderRedirect.asksForCollection(listing, at: "/plain/fx/photos"))
        let refusal = try Self.debian("delete-file-slashed-400")
        #expect(!WebDAVFolderRedirect.asksForCollection(refusal, at: "/plain/fx/notes.txt"))
    }

    @Test("only a redirect naming the path with a slash counts, and only a redirect status")
    func readsOnlyThatRedirect() {
        func answer(_ status: Int, _ location: String?) -> WebDAVHTTPResponse {
            WebDAVHTTPResponse(status: status, headers: location.map { ["Location": [$0]] } ?? [:])
        }
        let folder = "/plain/fx/photos"
        #expect(WebDAVFolderRedirect.asksForCollection(answer(308, "/plain/fx/photos/"), at: folder))
        // The authority is not compared: Apache builds it from the `Host` it was sent.
        #expect(WebDAVFolderRedirect.asksForCollection(
            answer(301, "https://nas.example:5006/plain/fx/photos/"),
            at: folder
        ))
        #expect(!WebDAVFolderRedirect.asksForCollection(answer(301, "/plain/fx/photos"), at: folder))
        #expect(!WebDAVFolderRedirect.asksForCollection(answer(301, nil), at: folder))
        #expect(
            !WebDAVFolderRedirect.asksForCollection(answer(303, "/plain/fx/photos/"), at: folder)
        )
        #expect(
            !WebDAVFolderRedirect.asksForCollection(answer(200, "/plain/fx/photos/"), at: folder)
        )
    }

    @Test("a MOVE's redirect names its source by Location, and its destination by none")
    func readsWhichEnd() throws {
        let source = "/plain/fx/inbox", destination = "/plain/fx/archive"
        let end = { (response: WebDAVHTTPResponse) in
            WebDAVFolderRedirect.redirectedEnd(response, source: source, destination: destination)
        }
        #expect(try end(Self.debian("move-folder-onto-folder-301")) == .source)
        #expect(try end(Self.debian("move-folder-onto-folder-dest-301")) == .destination)
        #expect(end(WebDAVHTTPResponse(status: 301, headers: ["Location": [destination + "/"]]))
            == .destination)
        // Somewhere else entirely is not a folder's spelling, and a refusal is not a redirect.
        #expect(end(WebDAVHTTPResponse(status: 301, headers: ["Location": ["https://other/"]]))
            == nil)
        #expect(try end(Self.debian("move-folder-onto-folder-412")) == nil)
    }

    // MARK: - Asking again

    @Test("a stat of a folder there is asked again with the slash, and a file once")
    func statsAFolder() throws {
        let transport = FakeWebDAVTransport { request in
            switch (request.path, request.isCollection) {
            case ("/photos", false): try Self.debian("propfind-folder-301")
            case ("/photos", true):
                try Self.debian("propfind-folder-207", body: "debian-photos-depth0-props")
            default: WebDAVHTTPResponse(status: 404)
            }
        }
        let entry = try backend(transport).stat(at: path("/photos"))
        #expect(entry.kind == .directory)
        #expect(entry.name == "photos")
        #expect(transport.propfinds.map(\.isCollection) == [false, true])
    }

    @Test("a folder there is deleted by a second DELETE naming it with its slash")
    func deletesAFolder() throws {
        let transport = transport { write in
            write == .delete("/pictures")
                ? try Self.debian("delete-folder-301")
                : try Self.debian("delete-folder-204")
        }
        try backend(transport).removeItem(at: path("/pictures"))
        #expect(transport.writes == [.delete("/pictures"), .delete("/pictures", isCollection: true)])
    }

    @Test("a folder there moves by a second MOVE naming its source with the slash")
    func movesAFolder() throws {
        let transport = transport { write in
            write == .move("/photos", to: "/pictures")
                ? try Self.debian("move-folder-301")
                : try Self.debian("move-folder-201")
        }
        try backend(transport).moveItem(at: path("/photos"), to: path("/pictures"))
        #expect(transport.writes == [
            .move("/photos", to: "/pictures"),
            .move("/photos", to: "/pictures", collections: .source)
        ])
    }

    @Test("a file moved onto a folder there is refused as taken, the folder named with its slash")
    func refusesAFolderDestination() throws {
        let transport = transport { write in
            write == .move("/notes.txt", to: "/photos")
                ? try Self.debian("move-onto-folder-301")
                : try Self.debian("move-onto-folder-412")
        }
        #expect(throws: VFSError.alreadyExists(path("/photos"))) {
            try backend(transport).moveItem(at: path("/notes.txt"), to: path("/photos"))
        }
        #expect(transport.writes == [
            .move("/notes.txt", to: "/photos"),
            .move("/notes.txt", to: "/photos", collections: .destination)
        ])
    }

    @Test("a folder moved onto a folder there takes three answers, and is refused as taken")
    func refusesAFolderOntoAFolder() throws {
        let transport = transport { write in
            switch write {
            case .move(_, _, collections: []): try Self.debian("move-folder-onto-folder-301")
            case .move(_, _, collections: .source):
                try Self.debian("move-folder-onto-folder-dest-301")
            default: try Self.debian("move-folder-onto-folder-412")
            }
        }
        #expect(throws: VFSError.alreadyExists(path("/archive"))) {
            try backend(transport).moveItem(at: path("/inbox"), to: path("/archive"))
        }
        #expect(transport.writes == [
            .move("/inbox", to: "/archive"),
            .move("/inbox", to: "/archive", collections: .source),
            .move("/inbox", to: "/archive", collections: [.source, .destination])
        ])
    }

    @Test("a COPY onto a folder there is refused as taken, and sends no bytes")
    func refusesACopyOntoAFolder() throws {
        let transport = transport { write in
            write == .copy("/other.txt", to: "/photos")
                ? try Self.debian("copy-onto-folder-301")
                : try Self.debian("copy-onto-folder-412")
        }
        #expect(throws: VFSError.alreadyExists(path("/photos"))) {
            try backend(transport).copyFile(
                at: path("/other.txt"),
                to: path("/photos"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(transport.writes == [
            .copy("/other.txt", to: "/photos"),
            .copy("/other.txt", to: "/photos", collections: .destination)
        ])
    }

    /// The guard against a server that redirects whatever it is sent: each end is named with its
    /// slash once, and what comes back after that is the answer.
    @Test("a redirect that keeps coming is asked again once per end, then reported")
    func asksAgainAtMostOncePerEnd() throws {
        let always = transport { _ in try Self.debian("move-folder-301") }
        #expect(throws: VFSError.io(path: path("/photos"), code: EIO)) {
            try backend(always).moveItem(at: path("/photos"), to: path("/pictures"))
        }
        #expect(always.writes.count == 2)

        let nowhere = transport { _ in try Self.debian("move-onto-folder-301") }
        #expect(throws: VFSError.io(path: path("/notes.txt"), code: EIO)) {
            try backend(nowhere).moveItem(at: path("/notes.txt"), to: path("/photos"))
        }
        #expect(nowhere.writes.count == 2)

        let deleting = transport { _ in try Self.debian("delete-folder-301") }
        #expect(throws: VFSError.io(path: path("/pictures"), code: EIO)) {
            try backend(deleting).removeItem(at: path("/pictures"))
        }
        #expect(deleting.writes.count == 2)
    }
}

// MARK: - A PUT, and the arguments

extension WebDAVFolderRedirectTests {
    @Test("an empty file onto a folder there is taken, in one request and no stat")
    func createFileOntoAFolder() throws {
        let transport = transport { _ in try Self.debian("put-onto-folder-301") }
        #expect(throws: VFSError.alreadyExists(path("/photos"))) {
            try backend(transport).createFile(at: path("/photos"))
        }
        #expect(transport.writes == [.putEmpty("/photos", condition: .ifAbsent)])
        #expect(transport.propfinds.isEmpty)
    }

    @Test("an upload onto a folder there is taken, and a save-back finds its file replaced")
    func uploadOntoAFolder() throws {
        let scratch = try WebDAVScratch()
        defer { scratch.remove() }
        let local = scratch.directory.appendingPathComponent("up.txt").path
        try Data("hello\n".utf8).write(to: URL(fileURLWithPath: local))
        let transport = transport { _ in try Self.debian("upload-onto-folder-301") }
        let dav = backend(transport)

        #expect(throws: VFSError.alreadyExists(path("/photos"))) {
            try dav.copyFile(
                at: .local(local),
                to: path("/photos"),
                progress: { _ in },
                isCancelled: { false }
            )
        }
        let save = { (condition: S3WriteCondition) in
            try dav.writeBack(
                localPath: local,
                to: path("/photos"),
                condition: condition,
                progress: { _ in },
                isCancelled: { false }
            )
        }
        #expect(throws: VFSError.unsupported(.remoteFileChangedSinceFetch(name: "photos"))) {
            try save(.ifMatches(entityTag: "\"abc\""))
        }
        #expect(throws: VFSError.alreadyExists(path("/photos"))) { try save(.unconditional) }
        #expect(transport.writes.count == 3, "a PUT is never sent again")
    }

    // MARK: - The arguments

    @Test("the slash is in a URL only where it was asked for")
    func spellsTheSlashWhenAsked() {
        let session = WebDAVSession(location: Self.location, authentication: nil)
        let bare = WebDAVProcessArguments.delete(session: session, backendPath: "/pictures")
        let slashed = WebDAVProcessArguments.delete(
            session: session,
            backendPath: "/pictures",
            isCollection: true
        )
        #expect(bare.last == "http://localhost:8092/plain/fx/pictures")
        #expect(slashed.last == "http://localhost:8092/plain/fx/pictures/")

        func move(_ collections: WebDAVCollectionEnds) -> (url: String?, destination: String?) {
            let arguments = WebDAVProcessArguments.move(
                session: session,
                backendPath: "/inbox",
                to: "/archive",
                collections: collections
            )
            return (arguments.last, arguments.first { $0.hasPrefix("Destination: ") })
        }
        let root = "http://localhost:8092/plain/fx"
        #expect(move([]).url == "\(root)/inbox")
        #expect(move([]).destination == "Destination: \(root)/archive")
        #expect(move(.source).url == "\(root)/inbox/")
        #expect(move(.source).destination == "Destination: \(root)/archive")
        #expect(move(.destination).url == "\(root)/inbox")
        #expect(move(.destination).destination == "Destination: \(root)/archive/")
        // Nothing asked: the very arguments every server got before.
        #expect(
            WebDAVProcessArguments.move(session: session, backendPath: "/inbox", to: "/archive")
                == WebDAVProcessArguments.move(
                    session: session,
                    backendPath: "/inbox",
                    to: "/archive",
                    collections: []
                )
        )
    }
}
